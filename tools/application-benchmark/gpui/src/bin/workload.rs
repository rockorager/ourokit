use std::{
    borrow::Cow,
    cell::RefCell,
    ops::Range,
    process::ExitCode,
    rc::Rc,
    time::{Duration, Instant},
};

use gpui::{
    App, Bounds, Context, Entity, FontWeight, IntoElement, Render, ScrollHandle, StyleRefinement,
    UniformListScrollHandle, Window, WindowBounds, WindowDecorations, WindowId, WindowOptions, div,
    point,
    prelude::*,
    profiler::{self, FrameEvent, FrameTimingCollector},
    px, rgb, size, uniform_list,
};
use serde_json::json;

const FONT: &[u8] = include_bytes!("../../../../../src/text/fonts/SourceSans3-Regular.otf");
const SETUP_FRAMES: usize = 3;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Profile {
    Scroll,
    Rebuild,
    Relayout,
    SparseParent,
    SparseLeaf,
    SustainedScroll,
    KeyedChurn,
}

impl Profile {
    fn name(self) -> &'static str {
        match self {
            Self::Scroll => "scroll",
            Self::Rebuild => "rebuild",
            Self::Relayout => "relayout",
            Self::SparseParent => "sparse-parent",
            Self::SparseLeaf => "sparse-leaf",
            Self::SustainedScroll => "sustained-scroll",
            Self::KeyedChurn => "keyed-churn",
        }
    }
    fn virtualized(self) -> bool {
        matches!(self, Self::Scroll | Self::SustainedScroll)
    }
    fn rows(self) -> usize {
        if self.virtualized() { 10_000 } else { 1_000 }
    }
    fn row_height(self, generation: usize) -> f32 {
        if self == Self::Relayout && generation % 2 == 1 {
            32.
        } else {
            28.
        }
    }
    fn offset(self, generation: usize) -> f32 {
        if self == Self::Scroll {
            14. * generation as f32
        } else if self == Self::SustainedScroll {
            let phase = generation % 4800;
            phase.min(4800 - phase) as f32 * 112.
        } else {
            0.
        }
    }
    // Zero-based row identity, independent of its current position.
    fn row_id(self, position: usize, generation: usize) -> usize {
        if self != Self::KeyedChurn {
            return position;
        }
        generation / 3 * 8
            + match generation % 3 {
                1 => 999 - position,
                2 => (position + 17) % 1000,
                _ => position,
            }
    }
    fn value(self, index: usize, generation: usize) -> usize {
        if self == Self::Rebuild
            || (matches!(self, Self::SparseParent | Self::SparseLeaf) && index == 6)
        {
            generation
        } else {
            0
        }
    }
}

#[derive(Clone, Copy)]
struct Options {
    profile: Profile,
    frames: usize,
    hold_ms: u64,
}

impl Options {
    fn parse() -> Result<Self, String> {
        let mut args = std::env::args().skip(1);
        let mut profile = None;
        let mut frames = None;
        let mut hold_ms = 0;
        while let Some(option) = args.next() {
            let value = args
                .next()
                .ok_or_else(|| format!("missing value for {option}"))?;
            match option.as_str() {
                "--profile" => {
                    profile = Some(match value.as_str() {
                        "scroll" => Profile::Scroll,
                        "rebuild" => Profile::Rebuild,
                        "relayout" => Profile::Relayout,
                        "sparse-parent" => Profile::SparseParent,
                        "sparse-leaf" => Profile::SparseLeaf,
                        "sustained-scroll" => Profile::SustainedScroll,
                        "keyed-churn" => Profile::KeyedChurn,
                        _ => return Err("unknown profile".into()),
                    })
                }
                "--frames" => frames = Some(value.parse::<usize>().map_err(|e| e.to_string())?),
                "--hold-ms" => hold_ms = value.parse::<u64>().map_err(|e| e.to_string())?,
                _ => return Err(format!("unknown option {option}")),
            }
        }
        let result = Self {
            profile: profile.ok_or("--profile required")?,
            frames: frames.ok_or("--frames required")?,
            hold_ms,
        };
        if result.frames == 0 || result.frames > 10_000 {
            return Err("--frames must be between 1 and 10000".into());
        }
        if result.profile.offset(result.frames - 1) > 10_000. * 28. - 720. {
            return Err("scroll frame count exceeds available content".into());
        }
        Ok(result)
    }
}

#[derive(Default)]
struct RowBuilds {
    ranges: Vec<Range<usize>>,
    count: usize,
}

impl RowBuilds {
    fn prepared() -> Self {
        // Touch trace storage before timing, including usual list sizing probes.
        let mut ranges = vec![0..0; 4];
        ranges.clear();
        Self { ranges, count: 0 }
    }
}

#[derive(Default)]
struct Counters {
    root_calls: usize,
    row_calls: usize,
    rendered_rows: Vec<(usize, usize)>,
}

struct Leaf {
    index: usize,
    value: usize,
    counters: Rc<RefCell<Counters>>,
    row_builds: Rc<RefCell<RowBuilds>>,
}

impl Render for Leaf {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let mut counters = self.counters.borrow_mut();
        counters.row_calls += 1;
        counters.rendered_rows[self.index] = (self.index, self.value);
        self.row_builds.borrow_mut().count += 1;
        row(self.index, self.value, 28.)
    }
}

#[derive(Default)]
struct Sample {
    frame: usize,
    build_ns: u128,
    submit_ns: u128,
    submitted_ns: u128,
    offset: f32,
    row_height: f32,
    row_builds: RowBuilds,
    first_row_bounds: Option<[f32; 4]>,
    root_calls: usize,
    row_calls: usize,
    checked_rows: usize,
    first_row: usize,
    first_value: usize,
    changed_value: usize,
}

#[derive(Default)]
struct Output {
    samples: Vec<Sample>,
    completed_frames: usize,
    epoch_ns: u128,
    complete: bool,
    error: Option<String>,
    active: Option<bool>,
    scale_factor: Option<f32>,
}

struct Workload {
    options: Options,
    generation: usize,
    setup_remaining: usize,
    collector: Option<FrameTimingCollector>,
    started: Option<Instant>,
    mutation_finished: Option<Instant>,
    list_scroll: UniformListScrollHandle,
    full_scroll: ScrollHandle,
    row_builds: Rc<RefCell<RowBuilds>>,
    counters: Rc<RefCell<Counters>>,
    leaves: Vec<Entity<Leaf>>,
    output: Rc<RefCell<Output>>,
}

fn timing_pair(
    events: &[FrameEvent],
    window: WindowId,
    mutation_finished: Instant,
) -> Result<(u128, u128, Instant), String> {
    let [FrameEvent::Draw(draw), FrameEvent::Present(present)] = events else {
        return Err(format!(
            "expected exactly one Draw/Present pair; received {events:?}"
        ));
    };
    if draw.window_id != window || present.window_id != window {
        return Err("profiler events belong to another window".into());
    }
    if draw.draw_start < mutation_finished
        || draw.draw_end < draw.draw_start
        || present.present_start < draw.draw_end
        || present.present_end < present.present_start
    {
        return Err("stale or non-monotonic profiler pair".into());
    }
    Ok((
        draw.draw_duration().as_nanos(),
        present.present_duration().as_nanos(),
        present.present_end,
    ))
}

impl Workload {
    fn step(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Err(error) = self.advance(window, cx) {
            self.output.borrow_mut().error = Some(error);
            profiler::set_trace_enabled(false);
            cx.quit();
        }
    }

    fn advance(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Result<(), String> {
        if window.viewport_size() != size(px(640.), px(720.)) {
            return Err(format!("unexpected viewport {:?}", window.viewport_size()));
        }
        if self.setup_remaining > 0 {
            self.setup_remaining -= 1;
            cx.on_next_frame(window, Self::step);
            return Ok(());
        }
        let active = window.is_window_active();
        let scale_factor = window.scale_factor();
        {
            let mut output = self.output.borrow_mut();
            output.active = Some(active);
            output.scale_factor = Some(scale_factor);
        }
        if !active || scale_factor != 1. {
            return Err(format!(
                "foreground scale-one window required: active={active}, scale_factor={scale_factor}"
            ));
        }
        if let Some(collector) = &mut self.collector {
            let events = collector.collect_unseen();
            let (build_ns, submit_ns, submitted) = timing_pair(
                &events,
                window.window_handle().window_id(),
                self.mutation_finished.ok_or("missing mutation timestamp")?,
            )?;
            let offset = if self.options.profile.virtualized() {
                -f32::from(self.list_scroll.0.borrow().base_handle.offset().y)
            } else {
                -f32::from(self.full_scroll.offset().y)
            };
            if offset != self.options.profile.offset(self.generation) {
                return Err(format!(
                    "generation {}: incorrect offset {offset}",
                    self.generation
                ));
            }
            let first_row_bounds = if self.options.profile.virtualized() {
                None
            } else {
                let b = self
                    .full_scroll
                    .bounds_for_item(0)
                    .ok_or("missing first row bounds")?;
                if b.size
                    != size(
                        px(640.),
                        px(self.options.profile.row_height(self.generation)),
                    )
                {
                    return Err(format!("incorrect row bounds {b:?}"));
                }
                Some([
                    b.origin.x.into(),
                    b.origin.y.into(),
                    b.size.width.into(),
                    b.size.height.into(),
                ])
            };
            let counters = self.counters.borrow();
            let first_index = if self.options.profile.virtualized() {
                (offset / 28.).floor() as usize
            } else {
                self.options.profile.row_id(0, self.generation)
            };
            let mut checked_rows = 0;
            if !self.options.profile.virtualized() {
                let origin = first_row_bounds.ok_or("missing row bounds")?;
                for position in 0..1000 {
                    let index = self.options.profile.row_id(position, self.generation);
                    let value = self.options.profile.value(index, self.generation);
                    if counters.rendered_rows[position] != (index, value) {
                        return Err(format!(
                            "stale row {position}: {:?}",
                            counters.rendered_rows[position]
                        ));
                    }
                    let b = self
                        .full_scroll
                        .bounds_for_item(position)
                        .ok_or("missing retained row")?;
                    if b.size
                        != size(
                            px(640.),
                            px(self.options.profile.row_height(self.generation)),
                        )
                        || b.origin
                            != point(
                                px(origin[0]),
                                px(origin[1]
                                    + position as f32
                                        * self.options.profile.row_height(self.generation)),
                            )
                    {
                        return Err(format!("incorrect retained row geometry {position}: {b:?}"));
                    }
                    checked_rows += 1;
                }
            } else if !self
                .row_builds
                .borrow()
                .ranges
                .iter()
                .any(|r| r.contains(&first_index))
            {
                return Err("visible row absent from uniform-list callback ranges".into());
            }
            let mut output = self.output.borrow_mut();
            let mut row_builds = RowBuilds::default();
            std::mem::swap(
                &mut row_builds,
                &mut output.samples[self.generation].row_builds,
            );
            std::mem::swap(&mut row_builds, &mut *self.row_builds.borrow_mut());
            output.samples[self.generation] = Sample {
                frame: self.generation,
                build_ns,
                submit_ns,
                submitted_ns: submitted
                    .duration_since(self.started.ok_or("missing epoch")?)
                    .as_nanos(),
                offset,
                row_height: self.options.profile.row_height(self.generation),
                row_builds,
                first_row_bounds,
                root_calls: counters.root_calls,
                row_calls: counters.row_calls,
                checked_rows,
                first_row: first_index + 1,
                first_value: self.options.profile.value(first_index, self.generation),
                changed_value: if matches!(
                    self.options.profile,
                    Profile::SparseParent | Profile::SparseLeaf
                ) {
                    counters.rendered_rows[6].1
                } else {
                    0
                },
            };
            output.completed_frames += 1;
            drop(output);
            drop(counters);
            if self.generation + 1 == self.options.frames {
                self.output.borrow_mut().complete = true;
                profiler::set_trace_enabled(false);
                window.set_window_title(&format!(
                    "GPUI workload complete: {} frame {}",
                    self.options.profile.name(),
                    self.generation
                ));
                if self.options.hold_ms == 0 {
                    cx.quit();
                } else {
                    let timer = cx
                        .background_executor()
                        .timer(Duration::from_millis(self.options.hold_ms));
                    cx.spawn(async move |_, cx| {
                        timer.await;
                        cx.update(|cx| cx.quit());
                    })
                    .detach();
                }
                return Ok(());
            }
            self.generation += 1;
        } else {
            profiler::set_trace_enabled(true);
            self.collector = Some(FrameTimingCollector::new());
            let mut clock = libc::timespec {
                tv_sec: 0,
                tv_nsec: 0,
            };
            if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut clock) } != 0 {
                return Err("CLOCK_MONOTONIC unavailable".into());
            }
            self.started = Some(Instant::now());
            self.output.borrow_mut().epoch_ns =
                clock.tv_sec as u128 * 1_000_000_000 + clock.tv_nsec as u128;
        }
        self.row_builds.borrow_mut().count = 0;
        self.row_builds.borrow_mut().ranges.clear();
        self.list_scroll.0.borrow().base_handle.set_offset(point(
            px(0.),
            px(-self.options.profile.offset(self.generation)),
        ));
        self.full_scroll.set_offset(point(px(0.), px(0.)));
        if self.options.profile == Profile::SparseLeaf {
            self.leaves[6].update(cx, |leaf, cx| {
                leaf.value = self.generation;
                cx.notify();
            });
        } else {
            cx.notify();
        }
        self.mutation_finished = Some(Instant::now());
        cx.on_next_frame(window, Self::step);
        Ok(())
    }
}

fn row(index: usize, value: usize, height: f32) -> impl IntoElement {
    div()
        .id(("row", index))
        .w(px(640.))
        .h(px(height))
        .flex_none()
        .p(px(4.))
        .bg(rgb(if index % 2 == 0 { 0xf1f5f9 } else { 0xffffff }))
        .child(format!("Row {:06} | value {:06}", index + 1, value))
}

impl Render for Workload {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        self.counters.borrow_mut().root_calls += 1;
        let row_height = self.options.profile.row_height(self.generation);
        let content = if self.options.profile.virtualized() {
            let stats = self.row_builds.clone();
            let counters = self.counters.clone();
            uniform_list("rows", 10_000, move |range, _, _| {
                let mut stats = stats.borrow_mut();
                stats.count += range.len();
                counters.borrow_mut().row_calls += range.len();
                stats.ranges.push(range.clone());
                range.map(|index| row(index, 0, 28.)).collect::<Vec<_>>()
            })
            .w(px(640.))
            .h(px(720.))
            .track_scroll(&self.list_scroll)
            .into_any_element()
        } else if self.options.profile == Profile::SparseLeaf {
            div()
                .id("rows")
                .w(px(640.))
                .h(px(720.))
                .flex()
                .flex_col()
                .overflow_y_scroll()
                .track_scroll(&self.full_scroll)
                .children(self.leaves.iter().cloned().map(|leaf| {
                    leaf.cached(
                        StyleRefinement::default()
                            .w(px(640.))
                            .h(px(28.))
                            .flex_none(),
                    )
                }))
                .into_any_element()
        } else {
            self.row_builds.borrow_mut().ranges.push(0..1000);
            self.row_builds.borrow_mut().count += 1000;
            let mut counters = self.counters.borrow_mut();
            counters.row_calls += 1000;
            for position in 0..1000 {
                let index = self.options.profile.row_id(position, self.generation);
                counters.rendered_rows[position] =
                    (index, self.options.profile.value(index, self.generation));
            }
            div()
                .id("rows")
                .w(px(640.))
                .h(px(720.))
                .flex()
                .flex_col()
                .overflow_y_scroll()
                .track_scroll(&self.full_scroll)
                .children(
                    counters
                        .rendered_rows
                        .iter()
                        .map(|&(index, value)| row(index, value, row_height)),
                )
                .into_any_element()
        };
        div()
            .w(px(640.))
            .h(px(720.))
            .overflow_hidden()
            .bg(rgb(0xffffff))
            .text_color(rgb(0x111827))
            .font_family("Source Sans 3")
            .font_weight(FontWeight::NORMAL)
            .text_size(px(14.))
            .line_height(px(18.5625))
            .whitespace_nowrap()
            .child(content)
    }
}

fn run(options: Options) -> Result<(), String> {
    let output = Rc::new(RefCell::new(Output {
        samples: (0..options.frames)
            .map(|_| Sample {
                row_builds: RowBuilds::prepared(),
                ..Sample::default()
            })
            .collect(),
        ..Output::default()
    }));
    let captured = output.clone();
    gpui_platform::application().run(move |cx: &mut App| {
        if let Err(error) = cx.text_system().add_fonts(vec![Cow::Borrowed(FONT)]) {
            captured.borrow_mut().error = Some(error.to_string());
            cx.quit();
            return;
        }
        let output = captured.clone();
        let opened = cx.open_window(
            WindowOptions {
                app_id: Some("dev.ourokit.benchmark.workload.gpui".into()),
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(640.), px(720.)),
                    cx,
                ))),
                window_decorations: Some(WindowDecorations::Server),
                ..Default::default()
            },
            |window, cx| {
                cx.new(|cx| {
                    cx.on_next_frame(window, Workload::step);
                    let counters = Rc::new(RefCell::new(Counters {
                        rendered_rows: (0..1000).map(|index| (index, 0)).collect(),
                        ..Counters::default()
                    }));
                    let row_builds = Rc::new(RefCell::new(RowBuilds::prepared()));
                    let leaves = if options.profile == Profile::SparseLeaf {
                        (0..1000)
                            .map(|index| {
                                cx.new(|_| Leaf {
                                    index,
                                    value: 0,
                                    counters: counters.clone(),
                                    row_builds: row_builds.clone(),
                                })
                            })
                            .collect()
                    } else {
                        Vec::new()
                    };
                    Workload {
                        options,
                        generation: 0,
                        setup_remaining: SETUP_FRAMES,
                        collector: None,
                        started: None,
                        mutation_finished: None,
                        list_scroll: UniformListScrollHandle::new(),
                        full_scroll: ScrollHandle::new(),
                        row_builds,
                        counters,
                        leaves,
                        output,
                    }
                })
            },
        );
        if let Err(error) = opened {
            captured.borrow_mut().error = Some(error.to_string());
            cx.quit();
        } else {
            cx.activate(true);
        }
    });
    let output = output.borrow();
    println!(
        "{}",
        json!({"kind":"metadata", "toolkit":"GPUI", "profile":options.profile.name(),
        "frames":options.frames, "completed_frames":output.completed_frames, "setup_callbacks":SETUP_FRAMES,
        "epoch_ns":output.epoch_ns, "epoch_pair_tolerance_ns":1_000_000,
        "font":"Source Sans 3", "font_size":14, "font_weight":400, "line_height":18.5625,
        "row_padding":4, "row_count":options.profile.rows(), "viewport":[640,720],
        "active":output.active, "scale_factor":output.scale_factor,
        "timing_boundaries":{"build_ns":"GPUI Window::draw CPU wall time",
        "submit_ns":"platform draw/submission CPU wall time (profiler Present)",
        "work_ns":"build_ns + submit_ns; state mutation excluded",
        "submitted_ns":"monotonic platform submission end relative to workload epoch; NOT compositor/GPU presentation"},
        "row_builds":"uniform_list ranges include sizing probes; sparse-leaf uses cached Entity rows with only row7 notified; counters record actual callbacks",
        "status":if output.complete {"complete"} else {"failed"}})
    );
    for sample in output.samples.iter().take(output.completed_frames) {
        println!(
            "{}",
            json!({"kind":"sample", "frame":sample.frame,
            "build_ns":sample.build_ns, "submit_ns":sample.submit_ns, "work_ns":sample.build_ns+sample.submit_ns,
            "submitted_ns":sample.submitted_ns, "offset":sample.offset, "row_height":sample.row_height,
            "row_build_count":sample.row_builds.count,
            "row_build_ranges":sample.row_builds.ranges.iter().map(|r| [r.start, r.end]).collect::<Vec<_>>(),
            "root_calls":sample.root_calls, "row_calls":sample.row_calls, "checked_rows":sample.checked_rows,
            "first_row":sample.first_row, "first_value":sample.first_value, "changed_value":sample.changed_value,
            "first_row_bounds":sample.first_row_bounds})
        );
    }
    if !output.complete {
        return Err(output
            .error
            .clone()
            .unwrap_or_else(|| "window closed before all frames were collected".into()));
    }
    Ok(())
}

fn main() -> ExitCode {
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("warn,gpui_wgpu=info"),
    )
    .init();
    match Options::parse().and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::profiler::{FrameTiming, PresentTiming};

    #[test]
    fn profiler_pairs_require_order_identity_and_freshness() {
        let start = Instant::now();
        let window = WindowId::from(7);
        let draw = FrameEvent::Draw(FrameTiming {
            window_id: window,
            dirty_at: None,
            invalidations: 1,
            draw_start: start + Duration::from_nanos(11),
            draw_end: start + Duration::from_nanos(34),
        });
        let present = FrameEvent::Present(PresentTiming {
            window_id: window,
            present_start: start + Duration::from_nanos(39),
            present_end: start + Duration::from_nanos(98),
            animation_interval: None,
        });
        assert_eq!(
            timing_pair(&[draw, present], window, start).unwrap(),
            (23, 59, start + Duration::from_nanos(98))
        );
        for events in [
            vec![],
            vec![draw],
            vec![present],
            vec![present, draw],
            vec![draw, draw, present],
            vec![draw, present, draw, present],
        ] {
            assert!(timing_pair(&events, window, start).is_err());
        }
        assert!(timing_pair(&[draw, present], WindowId::from(8), start).is_err());
        assert!(timing_pair(&[draw, present], window, start + Duration::from_nanos(12)).is_err());
    }

    #[test]
    fn retained_mutations_match_sparse_churn_and_reversal_boundaries() {
        for p in [Profile::SparseParent, Profile::SparseLeaf] {
            assert_eq!(p.value(5, 17), 0);
            assert_eq!(p.value(6, 17), 17);
            assert_eq!(p.value(7, 17), 0);
        }
        for (frame, first) in [(0, 0), (1, 999), (2, 17), (3, 8), (4, 1007), (5, 25)] {
            assert_eq!(Profile::KeyedChurn.row_id(0, frame), first);
        }
        assert_eq!(Profile::KeyedChurn.row_id(983, 2), 0);
        let ids = |frame| {
            (0..1000)
                .map(|p| Profile::KeyedChurn.row_id(p, frame))
                .collect::<std::collections::HashSet<_>>()
        };
        assert_eq!(ids(1), ids(2));
        assert_eq!(ids(2).intersection(&ids(3)).count(), 992);
        for (frame, offset) in [
            (2399, 268688.),
            (2400, 268800.),
            (2401, 268688.),
            (4799, 112.),
            (4800, 0.),
            (4801, 112.),
        ] {
            assert_eq!(Profile::SustainedScroll.offset(frame), offset);
        }
    }

    #[test]
    fn workload_geometry_distinguishes_half_rows_and_parity() {
        assert_eq!(Profile::Scroll.offset(0), 0.);
        assert_eq!(Profile::Scroll.offset(3), 42.);
        assert_eq!(Profile::Scroll.rows(), 10_000);
        assert_eq!(Profile::Rebuild.rows(), 1_000);
        assert_eq!(Profile::Relayout.row_height(0), 28.);
        assert_eq!(Profile::Relayout.row_height(1), 32.);
        assert_eq!(Profile::Relayout.row_height(2), 28.);
        assert_eq!(Profile::Rebuild.row_height(1), 28.);
        assert_eq!(Profile::Relayout.offset(3), 0.);
    }
}
