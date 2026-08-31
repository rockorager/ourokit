const std = @import("std");
const wayland_runner = @import("wayland_runner.zig");
const storybook_runner = @import("storybook_runner.zig");

const browser_prefix =
    \\local ouro = require("ouro")
    \\local function declaration(value)
    \\  return value
    \\end
    \\ouro.storybook = declaration
    \\ouro.story = declaration
    \\local catalog = (function()
;

const browser_suffix =
    \\end)()
    \\local selected = ouro.signal(1)
    \\local function viewport(story)
    \\  return story.viewport or {}
    \\end
    \\return ouro.app {
    \\  id = "dev.ourokit.storybook",
    \\  windows = {
    \\    ouro.window {
    \\      id = "storybook",
    \\      title = catalog.title or "Ourokit Storybook",
    \\      width = 1200,
    \\      height = 800,
    \\      content = function()
    \\        local current = selected()
    \\        local story = catalog.stories[current]
    \\        local story_viewport = viewport(story)
    \\        ouro.row {
    \\          key = "storybook-browser",
    \\          gap = 12,
    \\          children = function()
    \\            ouro.box {
    \\              key = "catalog-panel",
    \\              width = 260,
    \\              height = 752,
    \\              children = function()
    \\                ouro.scroll {
    \\                  key = "catalog-scroll",
    \\                  children = function()
    \\                    ouro.column {
    \\                      key = "catalog",
    \\                      gap = 8,
    \\                      children = function()
    \\                        ouro.label {
    \\                          key = "catalog-title",
    \\                          text = catalog.title or "Ourokit Storybook",
    \\                          size = 18,
    \\                        }
    \\                        local previous_group = nil
    \\                        for index = 1, #catalog.stories do
    \\                          local item = catalog.stories[index]
    \\                          local group = item.group or "Stories"
    \\                          if group ~= previous_group then
    \\                            ouro.label {
    \\                              key = "group-" .. index,
    \\                              text = group,
    \\                              size = 12,
    \\                            }
    \\                            previous_group = group
    \\                          end
    \\                          local story_index = index
    \\                          ouro.button {
    \\                            key = "story-" .. index,
    \\                            label = (index == current and "• " or "") .. item.name,
    \\                            width = 244,
    \\                            on_press = function()
    \\                              selected:set(story_index)
    \\                            end,
    \\                          }
    \\                        end
    \\                      end,
    \\                    }
    \\                  end,
    \\                }
    \\              end,
    \\            }
    \\            ouro.box {
    \\              key = "preview-area",
    \\              width = 900,
    \\              height = 752,
    \\              alignment = "center",
    \\              children = function()
    \\                ouro.scroll {
    \\                  key = "preview-vertical",
    \\                  children = function()
    \\                    ouro.scroll {
    \\                      key = "preview-horizontal",
    \\                      axis = "horizontal",
    \\                      children = function()
    \\                        ouro.theme {
    \\                          key = "preview-theme",
    \\                          color_scheme = story.color_scheme or "light",
    \\                          children = function()
    \\                            ouro.box {
    \\                              key = "preview",
    \\                              width = story_viewport.width or 640,
    \\                              height = story_viewport.height or 480,
    \\                              children = story.content,
    \\                            }
    \\                          end,
    \\                        }
    \\                      end,
    \\                    }
    \\                  end,
    \\                }
    \\              end,
    \\            }
    \\          end,
    \\        }
    \\      end,
    \\    },
    \\  },
    \\}
;

/// Runs an ordinary Ourokit application that mounts the validated catalog in
/// a native selectable browser. The catalog source remains the source of truth;
/// the wrapper supplies only browser state and layout.
pub fn run(
    init: std.process.Init,
    source: []const u8,
    options: wayland_runner.Options,
) !void {
    var description = try storybook_runner.describe(init, source);
    defer description.deinit();

    var application_source: std.Io.Writer.Allocating = .init(init.gpa);
    defer application_source.deinit();
    try application_source.writer.writeAll(browser_prefix);
    try application_source.writer.writeAll(source);
    try application_source.writer.writeByte('\n');
    try application_source.writer.writeAll(browser_suffix);
    try wayland_runner.run(init, application_source.written(), options);
}

test "browser wrapper retains catalog source inside an application" {
    const source =
        \\local ouro = require("ouro")
        \\return ouro.storybook {
        \\  title = "Controls",
        \\  stories = {
        \\    ouro.story { id = "one", name = "One", content = function() end },
        \\  },
        \\}
    ;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.writeAll(browser_prefix);
    try output.writer.writeAll(source);
    try output.writer.writeByte('\n');
    try output.writer.writeAll(browser_suffix);
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "local ouro = require(\"ouro\")"));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "local catalog = (function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "title = \"Controls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "return ouro.app") != null);
}
