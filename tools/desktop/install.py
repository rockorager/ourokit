#!/usr/bin/env python3
"""Generate or install freedesktop integration from explicit JSON metadata."""

import argparse
import json
import os
import re
import shlex
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


ID_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)+")
MIME_RE = re.compile(r"[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*")
SCHEME_RE = re.compile(r"[a-z][a-z0-9+.-]*")
SIZE_RE = re.compile(r"(?:[1-9][0-9]*x[1-9][0-9]*|scalable)")


def fail(message):
    raise ValueError(message)


def text(value, field):
    if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
        fail(f"{field} must be a non-empty string without control characters")
    return value


def absolute(value, field):
    value = text(value, field)
    if not Path(value).is_absolute() or "=" in value:
        fail(f"{field} must be an absolute path without '='")
    return value


def desktop_arg(value):
    """Quote one literal Desktop Entry Exec argument (not a shell word)."""
    out = []
    for char in value:
        if char == "\\":
            out.append("\\\\\\\\")
        elif char in ('"', "$", "`"):
            out.append("\\\\" + char)
        elif char == "%":
            out.append("%%")
        else:
            out.append(char)
    return '"' + "".join(out) + '"'


def desktop_value(value, field):
    value = text(value, field)
    return value.replace("\\", "\\\\")


def source_path(base, value, field):
    value = text(value, field)
    path = Path(value)
    path = path if path.is_absolute() else base / path
    if not path.is_file():
        fail(f"{field} is not a file: {path}")
    return path


def icon_record(base, raw, field, default_name, context):
    if not isinstance(raw, dict) or set(raw) - {"source", "size", "name"}:
        fail(f"{field} must contain only source, size, and optional name")
    source = source_path(base, raw.get("source"), field + ".source")
    size = text(raw.get("size"), field + ".size")
    if not SIZE_RE.fullmatch(size):
        fail(f"{field}.size must be WIDTHxHEIGHT or scalable")
    suffix = source.suffix.lower()
    if suffix not in (".png", ".svg") or (size == "scalable") != (suffix == ".svg"):
        fail(f"{field} must use SVG for scalable and PNG for fixed-size icons")
    name = text(raw.get("name", default_name), field + ".name")
    if "/" in name or not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        fail(f"{field}.name is not a safe icon name")
    return source, Path("share/icons/hicolor") / size / context / (name + suffix), name


def load(metadata):
    try:
        raw = json.loads(metadata.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read metadata: {error}")
    allowed = {"id", "name", "comment", "ouroctl", "manifest", "dbus_activation",
               "mime_types", "schemes", "categories", "icon", "custom_mime_xml", "mime_icons"}
    if not isinstance(raw, dict) or set(raw) - allowed:
        fail("metadata must be an object containing only documented keys")
    app_id = text(raw.get("id"), "id")
    if not ID_RE.fullmatch(app_id) or len(app_id) > 255:
        fail("id must be a dotted D-Bus application ID")
    name = desktop_value(raw.get("name"), "name")
    ouroctl = absolute(raw.get("ouroctl"), "ouroctl")
    if '%' in ouroctl:
        fail("ouroctl executable path must not contain '%' (desktop launcher compatibility)")
    manifest = absolute(raw.get("manifest"), "manifest")
    dbus = raw.get("dbus_activation", False)
    if type(dbus) is not bool:
        fail("dbus_activation must be boolean")

    def string_list(key, pattern=None):
        values = raw.get(key, [])
        if not isinstance(values, list) or any(not isinstance(v, str) for v in values):
            fail(f"{key} must be an array of strings")
        if len(set(values)) != len(values) or any(not v or (pattern and not pattern.fullmatch(v)) for v in values):
            fail(f"{key} contains an invalid or duplicate value")
        return values

    mimes = string_list("mime_types", MIME_RE)
    schemes = string_list("schemes", SCHEME_RE)
    categories = string_list("categories", re.compile(r"[A-Za-z0-9-]+"))
    files = []
    icon_name = None
    if "icon" in raw:
        source, destination, icon_name = icon_record(metadata.parent, raw["icon"], "icon", app_id, "apps")
        files.append((source, destination))
    custom = raw.get("custom_mime_xml")
    if custom is not None:
        source = source_path(metadata.parent, custom, "custom_mime_xml")
        try:
            root = ET.parse(source).getroot()
        except ET.ParseError as error:
            fail(f"custom_mime_xml is not well-formed XML: {error}")
        if root.tag != "{http://www.freedesktop.org/standards/shared-mime-info}mime-info":
            fail("custom_mime_xml must have the shared-mime-info mime-info root")
        files.append((source, Path("share/mime/packages") / f"{app_id}.xml"))
    mime_icons = raw.get("mime_icons", {})
    if not isinstance(mime_icons, dict) or any(mime not in mimes for mime in mime_icons):
        fail("mime_icons must map declared MIME types to icon records")
    for mime, record in mime_icons.items():
        source, destination, _ = icon_record(metadata.parent, record, f"mime_icons.{mime}",
                                              mime.replace("/", "-"), "mimetypes")
        files.append((source, destination))

    lines = ["[Desktop Entry]", "Type=Application", f"Name={name}"]
    if "comment" in raw:
        lines.append("Comment=" + desktop_value(raw["comment"], "comment"))
    handlers = mimes + ["x-scheme-handler/" + scheme for scheme in schemes]
    command = " ".join(desktop_arg(v) for v in (ouroctl, "run", manifest))
    lines.append("Exec=" + command + (" -- %U" if handlers else ""))
    if dbus:
        lines.append("DBusActivatable=true")
    lines.extend(["Terminal=false"])
    if icon_name:
        lines.append(f"Icon={icon_name}")
    if handlers:
        lines.append("MimeType=" + ";".join(handlers) + ";")
    if categories:
        lines.append("Categories=" + ";".join(categories) + ";")
    generated = [(bytes("\n".join(lines) + "\n", "utf-8"), Path("share/applications") / f"{app_id}.desktop")]
    if dbus:
        command = " ".join(shlex.quote(v) for v in (ouroctl, "run", manifest, "--dbus-activated"))
        # The service key-file parser unescapes backslashes before argv parsing.
        command = command.replace("\\", "\\\\")
        service = f"[D-BUS Service]\nName={app_id}\nExec={command}\n"
        generated.append((service.encode(), Path("share/dbus-1/services") / f"{app_id}.service"))
    generated.extend((source.read_bytes(), destination) for source, destination in files)
    return generated


def write_tree(entries, root):
    for contents, relative in entries:
        destination = root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.' + destination.name,
                                         delete=False) as output:
            temporary = Path(output.name)
            try:
                output.write(contents)
                output.flush()
                os.fchmod(output.fileno(), 0o644)
                os.replace(temporary, destination)
            finally:
                temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metadata", type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path, help="generate a PREFIX-like tree here")
    mode.add_argument("--user", action="store_true", help="install under XDG_DATA_HOME")
    mode.add_argument("--prefix", type=Path, help="installation prefix (for example /usr)")
    parser.add_argument("--destdir", type=Path, help="packaging staging root; only valid with --prefix")
    args = parser.parse_args()
    try:
        if args.destdir and args.prefix is None:
            fail("--destdir is only valid with --prefix")
        entries = load(args.metadata.resolve())
        if args.output:
            root = args.output
        elif args.user:
            value = os.environ.get("XDG_DATA_HOME")
            root = Path(value) if value else Path.home() / ".local/share"
            if not root.is_absolute():
                fail("XDG_DATA_HOME must be absolute")
            entries = [(data, path.relative_to("share")) for data, path in entries]
        else:
            if not args.prefix.is_absolute() or '..' in args.prefix.parts:
                fail("--prefix must be absolute without '..' components")
            root = (args.destdir / args.prefix.relative_to("/")) if args.destdir else args.prefix
        write_tree(entries, root)
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
