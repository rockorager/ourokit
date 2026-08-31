pub const Vm = @import("vm.zig").Vm;
pub const TaskHandle = @import("vm.zig").TaskHandle;
pub const TaskArgument = @import("vm.zig").Argument;
pub const CallbackRegistry = @import("callbacks.zig").CallbackRegistry;
pub const CallbackHandle = @import("callbacks.zig").CallbackHandle;
pub const ActiveBuildOwner = @import("ui_build.zig").ActiveBuildOwner;
pub const Signals = @import("signals.zig").Signals;
pub const SignalOwnerRef = @import("signals.zig").OwnerRef;
pub const UiBuild = @import("ui_build.zig").UiBuild;
pub const UiBuildArgument = @import("ui_build.zig").Argument;
pub const UiBuildCallback = @import("ui_build.zig").Callback;
pub const PreparedBuild = @import("prepared_build.zig").PreparedBuild;
pub const PreparedHandler = @import("prepared_build.zig").Handler;
pub const PreparedButton = @import("prepared_build.zig").Button;
pub const Application = @import("application.zig").Application;
pub const ApplicationWindow = @import("application.zig").Window;
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;
pub const DiagnosticPhase = @import("diagnostic.zig").Phase;
pub const recordDiagnosticError = @import("diagnostic.zig").recordError;
pub const ModuleLoader = @import("module_loader.zig").ModuleLoader;

test {
    _ = @import("application.zig");
    _ = @import("callbacks.zig");
    _ = @import("diagnostic.zig");
    _ = @import("prepared_build.zig");
    _ = @import("signals.zig");
    _ = @import("module_loader.zig");
    _ = @import("vm.zig");
    _ = @import("ui_build.zig");
}
