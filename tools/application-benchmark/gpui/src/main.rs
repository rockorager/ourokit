use gpui::{
    App, Bounds, Context, IntoElement, Render, Window, WindowBounds, WindowDecorations,
    WindowOptions, div, prelude::*, px, rgb, size,
};

struct Benchmark {
    settings: bool,
    count: usize,
}

impl Render for Benchmark {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let button = div()
            .id("increment")
            .w(px(160.))
            .h(px(if self.settings { 40. } else { 44. }))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(6.))
            .bg(rgb(0x2563eb))
            .text_color(rgb(0xffffff))
            .cursor_pointer()
            .on_click(cx.listener(|this, _, window, cx| {
                this.count += 1;
                window.set_window_title(&format!("GPUI benchmark: {}", this.count));
                cx.notify();
            }))
            .child(if self.settings {
                "Increment"
            } else if self.count % 2 == 0 {
                "Benchmark"
            } else {
                "Clicked"
            });
        let content = if self.settings {
            div()
                .flex()
                .flex_col()
                .gap(px(12.))
                .child(div().text_size(px(18.)).child("Ourokit controls"))
                .child(format!("Pressed {} times", self.count))
                .child(
                    div().flex().gap(px(8.)).child(button).child(
                        div()
                            .w(px(160.))
                            .h(px(40.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(6.))
                            .bg(rgb(0xd1d5db))
                            .text_color(rgb(0x6b7280))
                            .child("Disabled"),
                    ),
                )
                .into_any_element()
        } else {
            button.into_any_element()
        };
        div()
            .size_full()
            .p(px(12.))
            .bg(rgb(0xffffff))
            .text_color(rgb(0x111827))
            .text_size(px(14.))
            .child(content)
    }
}

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let settings = match args.as_slice() {
        [] => false,
        [option] if option == "--settings" => true,
        _ => panic!("usage: ourokit-gpui-benchmark [--settings]"),
    };
    // Retain adapter selection in the harness's per-launch diagnostics.
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("warn,gpui_wgpu=info"),
    )
    .init();
    gpui_platform::application().run(move |cx: &mut App| {
        let dimensions = if settings { (560., 360.) } else { (480., 320.) };
        let bounds = Bounds::centered(None, size(px(dimensions.0), px(dimensions.1)), cx);
        cx.open_window(
            WindowOptions {
                app_id: Some("dev.ourokit.benchmark.gpui".into()),
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_decorations: Some(WindowDecorations::Server),
                ..Default::default()
            },
            |window, cx| {
                window.set_window_title("GPUI benchmark: 0");
                cx.new(|_| Benchmark { settings, count: 0 })
            },
        )
        .expect("open benchmark window");
        cx.activate(true);
    });
}
