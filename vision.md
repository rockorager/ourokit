# Ourokit product vision

Ourokit is a toolkit for building performant Linux desktop applications, with
development tools that let people and agents inspect, debug, and iterate quickly.
It includes the UI and desktop integration needed to ship a complete application.
Shell-building capabilities are extensions to that toolkit, not its organizing
principle.

This document describes the intended product, not the current implementation or
a promise that every capability already exists. Architecture and API choices
should serve this vision rather than preserve earlier assumptions.

## Ordinary Linux applications come first

An Ourokit application belongs on the user's existing Linux desktop. It should
launch normally, open documents, respect desktop preferences, support assistive
technology, and cooperate with other applications without requiring a particular
desktop environment, toolkit-specific settings service, or agent connection.

Ourokit is Linux-only. Its desktop target is Wayland, with headless execution for
development and testing. Cross-platform abstractions are not a product goal.
Linux-only does not mean replacing established Linux libraries or protocols for
their own sake.

Panels, launchers, and other shell components may need layer-shell, workspace
control, and compositor-specific capabilities. Those extensions must not impose
their lifecycle, dependencies, or configuration model on ordinary applications.

## Performance is observable application behavior

Applications should start quickly, respond promptly, scroll smoothly, and do
little work while idle. Memory and CPU costs should remain reasonable as content
and application complexity grow. Development iteration should also be fast.

Performance claims need representative measurements: startup to visible content,
input-to-frame latency, frame pacing, idle CPU and wakeups, memory use, and
edit-to-visible latency. Small benchmarks help explain costs but do not establish
whole-application performance by themselves.

Implementation choices such as the event loop, renderer, caching, and retention
model are means to these outcomes. They are not the product promise. Performance
must not come from omitting text correctness, accessibility, or desktop behavior
that a complete application needs.

## Agent-first means a complete development loop

A developer or agent should be able to launch an isolated application instance,
inspect its current state, reproduce a problem, edit the source, reload it, and
verify the result without adding application-specific debugging code.

Development tools should expose:

- semantic UI identity, roles, values, bounds, focus, and available interactions;
- source context and structured diagnostics that make failures actionable;
- input replay and frame capture through the application's real runtime paths;
- rebuild, layout, rendering, and resource measurements that explain costs; and
- reload with explicit state-preservation rules and a usable last-good application
  when replacement source fails validation.

Human-facing tools, CLI commands, and agent integrations should use the same
underlying operations. Structured inspection complements screenshots; neither
alone is sufficient. Headless tests should share application behavior with the
desktop runtime, while platform integration still needs real desktop testing.

Agent-first development does not require every shipped application to be an MCP
server or expose its internals to automation.

## Desktop batteries reduce application work

Batteries included means an application author does not have to assemble basic
desktop behavior from protocol primitives. The supported surface should include
useful widgets and composition, text and images, accessible semantics, keyboard
navigation, input methods, clipboard and drag-and-drop, dialogs, notifications,
URI and document opening, desktop preferences, and installation conventions.

Use established desktop interfaces where they exist. For example, appearance
preferences come from the Settings portal over D-Bus.
Desktop activation and document opening follow desktop-entry
and `org.freedesktop.Application` conventions. Portals are useful desktop
interfaces, not merely a sandbox accommodation.

Capabilities vary across desktops. Missing optional services should have clear
fallbacks or explicit unsupported results, without hanging startup or silently
pretending an operation succeeded. Following desktop preferences does not require
imitating every toolkit's visual theme.

Application-owned preferences, desktop appearance preferences, and compositor
configuration are distinct responsibilities. A general-purpose shared settings
service is not a prerequisite for using Ourokit.

## Development control is not application control

Development control targets one running instance. It is enabled explicitly for
development, independently of the application's production automation features.
It owns inspection, test input, diagnostics, profiling, frame capture, and source
reload. Its endpoint is private to the development session and disappears with
that instance. Multiple development copies of the same app must coexist without
redirecting into an installed production instance.

Application control exposes operations the application intentionally supports:
activation, document opening, named actions, and application-specific services.
It uses stable application identity and may support desktop or D-Bus activation.
An ordinary application need not become a persistent background service.

These surfaces have separate enablement, endpoints, discovery, and authority.
Application automation does not grant development access. Development discovery
must not launch or attach to production applications implicitly. Inspection data
can contain private application content and must be treated accordingly; a
same-user connection is not a substitute for explicit development enablement.

Shared transport and dispatch implementation is appropriate. A shared public
control surface is not. MCP may serve development tools or optional production
agent integrations, but it is not the mandatory bus for Linux desktop behavior.

## A small supported surface can include substantial functionality

Application authors should primarily work with composition, state, tasks,
windows, widgets, assets, and convenient desktop APIs. Low-level protocol access
and native extensions provide escape hatches when an application needs them.

Well-factored internals do not each need to become an independently supported
SDK. Public APIs should follow demonstrated application needs, not expose every
renderer, event-loop, or lifecycle mechanism. Native extension contracts should
grow from concrete use cases rather than anticipate every possible host.

Ourokit is not a desktop environment, a compositor configuration system, a
package manager, or a general-purpose agent service framework. Shell extensions
and optional automation remain useful without becoming prerequisites.

## What success looks like

Success means a useful application can be developed, tested, installed, and used
on ordinary Linux desktops without toolkit-specific desktop services. A person
or agent can diagnose its UI, reproduce an interaction, make a change, and verify
that change quickly. The application remains responsive, accessible, and
economical to run.
