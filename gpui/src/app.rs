mod equalizer;
use crate::{native, response::*};
use gpui::{prelude::*, *};
use gpui_component::{
    button::*,
    input::{Input as TextInput, InputEvent, InputState},
    menu::*,
    *,
};
use serde_json::{Value, json};
use std::{cell::Cell, collections::HashMap, rc::Rc, time::Duration};

#[derive(Clone)]
struct Field {
    state: Entity<InputState>,
    baseline: String,
    command: Value,
    range: Option<(f64, f64)>,
    step: f64,
}

pub struct MonoSplit {
    data: Value,
    graphic: bool,
    eq_focus: FocusHandle,
    slider_bounds: Rc<Cell<Bounds<Pixels>>>,
    sliding: Option<usize>,
    selected_slider: usize,
    preset_edit_id: String,
    preset_query: String,
    role: usize,
    page: usize,
    phase: bool,
    include_master: bool,
    selected_band: String,
    fields: HashMap<String, Field>,
    active_field: Option<String>,
    subscriptions: Vec<Subscription>,
    poll: Option<Task<()>>,
    modal: String,
    draft: String,
    pair_role: usize,
    pair_shape: String,
    pair_frequency: f64,
    error: String,
    plot_bounds: Rc<Cell<Bounds<Pixels>>>,
    dragging: String,
    hover: Option<f64>,
    appearance: String,
    spl_min: f64,
    spl_max: f64,
}

fn color(role: usize, dark: bool) -> Hsla {
    let colors = if dark {
        [0x79aaff, 0xc09eff, 0x6fd4bb]
    } else {
        [0x326ec8, 0x8060b9, 0x208470]
    };
    rgb(colors[role.min(2)]).into()
}
fn label(value: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_xs()
        .text_color(cx.theme().muted_foreground)
        .child(value.into())
}
fn panel(cx: &App) -> Div {
    div()
        .flex()
        .flex_col()
        .gap_3()
        .p_4()
        .rounded_lg()
        .bg(cx.theme().background)
        .border_1()
        .border_color(cx.theme().border)
}
fn format_num(value: f64) -> String {
    let s = format!("{value:.4}");
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}
fn button(id: impl Into<SharedString>, title: impl Into<SharedString>) -> Button {
    Button::new(id.into()).label(title).small()
}

impl MonoSplit {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        native::init();
        let data = native::snapshot().unwrap_or(json!({}));
        let mut view = Self {
            data,
            graphic: true,
            eq_focus: cx.focus_handle(),
            slider_bounds: Rc::new(Cell::new(Bounds::default())),
            sliding: None,
            selected_slider: 0,
            preset_edit_id: String::new(),
            preset_query: String::new(),
            role: 0,
            page: 0,
            phase: false,
            include_master: false,
            selected_band: String::new(),
            fields: HashMap::new(),
            active_field: None,
            subscriptions: vec![],
            poll: None,
            modal: String::new(),
            draft: String::new(),
            pair_role: 0,
            pair_shape: "linkwitzRiley24".into(),
            pair_frequency: 200.,
            error: String::new(),
            plot_bounds: Rc::new(Cell::new(Bounds::default())),
            dragging: String::new(),
            hover: None,
            appearance: "system".into(),
            spl_min: 20.,
            spl_max: 110.,
        };
        Theme::change(
            if flag(&view.data, "dark") {
                ThemeMode::Dark
            } else {
                ThemeMode::Light
            },
            Some(window),
            cx,
        );
        view.poll = Some(cx.spawn_in(window, async move |view, cx| {
            loop {
                smol::Timer::after(Duration::from_millis(100)).await;
                if view
                    .update_in(cx, |this, window, cx| {
                        this.pull(window, cx);
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
        view
    }
    fn channel(&self) -> Value {
        values(&self.data["display"], "channels")
            .get(self.role)
            .cloned()
            .unwrap_or(json!({}))
    }
    pub fn select_role(&mut self, index: usize, cx: &mut Context<Self>) {
        native::send(&json!({"action":"endComparison"}));
        self.role = index.min(2);
        self.fields.clear();
        self.subscriptions.clear();
        self.selected_band.clear();
        self.selected_slider = 0;
        native::send(
            &json!({"action":"set","scope":"channel","role":ROLES[self.role],"field":"showCurve","value":true}),
        );
        cx.notify();
    }
    fn comparing(&self) -> bool {
        self.data["comparing"].as_str() == Some(ROLES[self.role])
    }
    fn pull(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Ok(next) = native::snapshot() {
            if flag(&next, "shutdownComplete") {
                cx.quit();
                return;
            }
            if next != self.data {
                if next["profile"]["id"] != self.data["profile"]["id"] {
                    self.fields.clear();
                    self.subscriptions.clear();
                    self.selected_band.clear();
                }
                self.data = next;
                if self.appearance == "system" {
                    let mode = if flag(&self.data, "dark") {
                        ThemeMode::Dark
                    } else {
                        ThemeMode::Light
                    };
                    if cx.theme().mode != mode {
                        Theme::change(mode, Some(window), cx);
                    }
                }
                cx.notify();
            }
        }
    }
    fn dispatch(&mut self, command: Value, window: &mut Window, cx: &mut Context<Self>) {
        let action = text(&command, "action");
        if action != "set" && action != "local" {
            if let Some(key) = self.active_field.take() {
                self.commit_field(&key, window, cx);
            }
        }
        if action == "ui" {
            match command["kind"].as_str().unwrap_or("") {
                "role" => self.select_role(command["index"].as_u64().unwrap_or(0) as usize, cx),
                "eqView" => self.graphic = flag(&command, "graphic"),
                "presetModal" => {
                    self.modal = text(&command, "value");
                    self.preset_edit_id = text(&command, "id");
                    self.draft = text(&command, "name");
                    self.fields.retain(|k, _| !k.starts_with("modal"));
                }
                "savePreset" => {
                    native::send(
                        &json!({"action":"savePreset","role":ROLES[self.role],"name":self.draft}),
                    );
                    if native::snapshot()
                        .ok()
                        .is_some_and(|v| text(&v, "message") == "EQ 预设已保存")
                    {
                        self.modal.clear();
                    }
                }
                "renamePreset" => {
                    native::send(
                        &json!({"action":"renamePreset","id":self.preset_edit_id,"name":self.draft}),
                    );
                    if native::snapshot()
                        .ok()
                        .is_some_and(|v| text(&v, "message") == "EQ 预设已保存")
                    {
                        self.modal.clear();
                    }
                }
                "deletePreset" => {
                    native::send(&json!({"action":"deletePreset","id":self.preset_edit_id}));
                    self.modal.clear();
                }
                "buildGraphic" => {
                    native::send(&json!({"action":"buildGraphic","role":ROLES[self.role]}));
                    self.modal.clear();
                }
                "page" => self.page = command["index"].as_u64().unwrap_or(0) as usize,
                "phase" => self.phase = !self.phase,
                "master" => self.include_master = !self.include_master,
                "band" => self.selected_band = text(&command, "id"),
                "modal" => {
                    self.modal = text(&command, "value");
                    self.draft = text(&self.data["profile"], "name");
                    self.fields.retain(|k, _| !k.starts_with("modal"));
                }
                "close" => {
                    self.modal.clear();
                    self.error.clear();
                }
                "pair" => {
                    let c = self.channel();
                    self.pair_frequency = number(&c["lowPass"], "frequency").max(20.);
                    self.pair_role = self.role.min(1);
                    self.modal = "pair".into();
                    self.fields.retain(|k, _| !k.starts_with("modal"));
                }
                "pairRole" => self.pair_role = command["index"].as_u64().unwrap_or(0) as usize,
                "pairShape" => self.pair_shape = text(&command, "value"),
                "applyPair" => {
                    native::send(
                        &json!({"action":"pair","role":ROLES[self.pair_role],"frequency":self.pair_frequency,"shape":self.pair_shape}),
                    );
                    self.modal.clear();
                }
                "rename" => {
                    native::send(&json!({"action":"renameProfile","name":self.draft}));
                    self.modal.clear();
                }
                "appearance" => {
                    self.appearance = text(&command, "value");
                    native::send(&json!({"action":"appearance","value":self.appearance}));
                    let dark = self.appearance == "dark"
                        || self.appearance == "system" && flag(&self.data, "dark");
                    Theme::change(
                        if dark {
                            ThemeMode::Dark
                        } else {
                            ThemeMode::Light
                        },
                        Some(window),
                        cx,
                    );
                }
                "splMin" => self.spl_min = number(&command, "value"),
                "splMax" => self.spl_max = number(&command, "value"),
                _ => {}
            }
            self.pull(window, cx);
            cx.notify();
            return;
        }
        if action == "local" {
            match command["field"].as_str().unwrap_or("") {
                "rename" => self.draft = text(&command, "value"),
                "presetQuery" => self.preset_query = text(&command, "value"),
                "pair" => self.pair_frequency = number(&command, "value"),
                "splMin" => self.spl_min = number(&command, "value"),
                "splMax" => self.spl_max = number(&command, "value"),
                _ => {}
            }
            cx.notify();
            return;
        }
        native::send(&command);
        if action == "deleteProfile" || action == "applyEQ" || action == "cancelEQ" {
            self.modal.clear();
        }
        self.error.clear();
        self.pull(window, cx);
        cx.notify();
    }
    fn cmd_button(
        &self,
        id: impl Into<SharedString>,
        title: impl Into<SharedString>,
        cmd: Value,
        cx: &mut Context<Self>,
    ) -> Button {
        button(format!("{}/{}",self.role,id.into()), title).on_click(
            cx.listener(move |this, _, window, cx| this.dispatch(cmd.clone(), window, cx)),
        )
    }
    fn menu_button(
        &self,
        id: impl Into<SharedString>,
        title: impl Into<SharedString>,
        entries: Vec<(String, Value)>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        button(format!("{}/{}",self.role,id.into()), title)
            .dropdown_menu(move |mut menu, _, _| {
                for (name, command) in entries.clone() {
                    let view = view.clone();
                    menu = menu.item(PopupMenuItem::new(name).on_click(move |_, window, cx| {
                        let _ =
                            view.update(cx, |this, cx| this.dispatch(command.clone(), window, cx));
                    }));
                }
                menu
            })
            .into_any_element()
    }
    fn setting(&self, scope: &str, field: &str, value: Value, id: Option<&str>) -> Value {
        let mut command = json!({"action":"set","scope":scope,"role":ROLES[self.role],"field":field,"value":value});
        if let Some(id) = id {
            command["id"] = json!(id);
        }
        command
    }
    fn commit_field(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(field) = self.fields.get(key).cloned() else {
            return;
        };
        let draft = field.state.read(cx).value().to_string();
        if draft == field.baseline {
            return;
        }
        let mut command = field.command.clone();
        if let Some((min, max)) = field.range {
            match draft.trim().replace('−', "-").parse::<f64>() {
                Ok(number) if number.is_finite() && number >= min && number <= max => {
                    command["value"] = json!(number)
                }
                _ => {
                    self.error = format!("请输入 {min} 至 {max} 的有效数值，按 Esc 恢复。");
                    cx.notify();
                    return;
                }
            }
        } else {
            command["value"] = json!(draft);
        }
        self.dispatch(command, window, cx);
    }
    fn input(
        &mut self,
        key: String,
        value: String,
        cmd: Value,
        range: Option<(f64, f64)>,
        step: f64,
        disabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let created = !self.fields.contains_key(&key);
        if created {
            let state = cx.new(|cx| InputState::new(window, cx).default_value(value.clone()));
            let field_key = key.clone();
            let subscription =
                cx.subscribe_in(&state, window, move |this, _, event, window, cx| {
                    if matches!(event, InputEvent::Focus) {
                        this.active_field = Some(field_key.clone());
                    }
                    if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur)
                        || matches!(event, InputEvent::Change)
                            && this
                                .fields
                                .get(&field_key)
                                .is_some_and(|f| f.range.is_none())
                    {
                        this.commit_field(&field_key, window, cx);
                    }
                });
            self.subscriptions.push(subscription);
            self.fields.insert(
                key.clone(),
                Field {
                    state,
                    baseline: value.clone(),
                    command: cmd.clone(),
                    range,
                    step,
                },
            );
        }
        let field = self.fields.get_mut(&key).unwrap();
        field.command = cmd;
        field.range = range;
        field.step = step;
        if field.baseline != value {
            field.baseline = value.clone();
            if field.state.read(cx).value().as_str() != value {
                field
                    .state
                    .update(cx, |state, cx| state.set_value(value.clone(), window, cx));
            }
        }
        let entity = field.state.clone();
        if created && key.starts_with("modal") {
            entity.update(cx, |state, cx| state.focus(window, cx));
        }
        let key2 = key.clone();
        div()
            .id(SharedString::from(key))
            .w_full()
            .capture_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
                if disabled {
                    return;
                }
                let Some(field) = this.fields.get(&key2).cloned() else {
                    return;
                };
                let k = event.keystroke.key.as_str();
                if k == "escape" && key2.starts_with("modal") {
                    this.modal.clear();
                    this.error.clear();
                    cx.stop_propagation();
                    cx.notify();
                    return;
                }
                if k == "escape" {
                    field.state.update(cx, |state, cx| {
                        state.set_value(field.baseline.clone(), window, cx)
                    });
                    this.error.clear();
                    cx.stop_propagation();
                    cx.notify();
                }
                if k == "up" || k == "down" {
                    if let Some((min, max)) = field.range {
                        let value = field
                            .state
                            .read(cx)
                            .value()
                            .parse::<f64>()
                            .unwrap_or_else(|_| field.baseline.parse().unwrap_or(0.));
                        let factor = if event.keystroke.modifiers.shift {
                            10.
                        } else if event.keystroke.modifiers.alt {
                            0.1
                        } else {
                            1.
                        };
                        let next = (value + field.step * factor * if k == "up" { 1. } else { -1. })
                            .clamp(min, max);
                        field.state.update(cx, |state, cx| {
                            state.set_value(format_num(next), window, cx)
                        });
                        this.commit_field(&key2, window, cx);
                        cx.stop_propagation();
                    }
                }
            }))
            .child(TextInput::new(&entity).small().disabled(disabled))
    }
    fn numeric(
        &mut self,
        field: &str,
        value: f64,
        range: (f64, f64),
        unit: &str,
        width: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let key = format!(
            "{}/{}/{}",
            text(&self.data["profile"], "id"),
            self.role,
            field
        );
        let cmd = self.setting("channel", field, json!(value), None);
        let input = self.input(
            key,
            format_num(value),
            cmd,
            Some(range),
            if field == "delayMS" { 0.01 } else { 0.1 },
            self.comparing(),
            window,
            cx,
        );
        div()
            .flex()
            .items_center()
            .gap_1()
            .w(px(width))
            .child(div().flex_1().child(input))
            .child(label(SharedString::from(unit.to_owned()), cx))
    }
    fn header(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let profiles = values(&self.data, "profiles")
            .iter()
            .map(|p| {
                (
                    text(p, "name"),
                    json!({"action":"selectProfile","id":p["id"]}),
                )
            })
            .collect();
        let running = flag(&self.data, "requested");
        div()
            .flex()
            .items_center()
            .justify_between()
            .px_5()
            .h(px(62.))
            .flex_shrink_0()
            .border_b_1()
            .border_color(cx.theme().border)
            .bg(cx.theme().background)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .text_xl()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("MonoSplit"),
                    )
                    .child(label("单声道 · 独立调音", cx)),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        self.cmd_button("undo", "撤销", json!({"action":"undo"}), cx)
                            .disabled(!flag(&self.data, "canUndo")),
                    )
                    .child(
                        self.cmd_button("redo", "重做", json!({"action":"redo"}), cx)
                            .disabled(!flag(&self.data, "canRedo")),
                    )
                    .child(self.menu_button(
                        "profiles",
                        format!("{}  ▾", text(&self.data["profile"], "name")),
                        profiles,
                        cx,
                    ))
                    .child(self.cmd_button(
                        "manage",
                        "管理配置",
                        json!({"action":"ui","kind":"page","index":2}),
                        cx,
                    ))
                    .child(
                        self.cmd_button(
                            "guide",
                            "使用指南",
                            json!({"action":"ui","kind":"modal","value":"guide"}),
                            cx,
                        )
                        .ghost(),
                    )
                    .child(
                        self.cmd_button(
                            "run",
                            if running {
                                "停止处理"
                            } else {
                                "启动处理"
                            },
                            json!({"action":"run"}),
                            cx,
                        )
                        .primary()
                        .disabled(
                            flag(&self.data, "busy")
                                || !running && !values(&self.data, "issues").is_empty(),
                        ),
                    ),
            )
    }
    fn sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let channels = values(&self.data["display"], "channels");
        let any_solo = channels
            .iter()
            .any(|c| flag(c, "enabled") && flag(c, "solo"));
        let mut cards = vec![];
        for (i, ch) in channels.iter().enumerate().take(3) {
            let accent = color(i, cx.theme().mode.is_dark());
            let selected = self.role == i;
            let device = values(&self.data, "devices")
                .into_iter()
                .find(|d| d["uid"] == ch["deviceUID"])
                .map(|d| text(&d, "name"))
                .unwrap_or_else(|| "选择输出设备".into());
            let peak = self.data["peaks"][i].as_f64().unwrap_or(0.);
            let db = if peak > 1e-6 {
                format!("{:.1}", 20. * peak.log10())
            } else {
                "−∞".into()
            };
            let status = if !flag(ch, "enabled") {
                "已关闭".into()
            } else if flag(ch, "muted") {
                "已静音".into()
            } else if any_solo && !flag(ch, "solo") {
                "其他声道独听中".into()
            } else if flag(ch, "solo") {
                "独听中".into()
            } else {
                format!(
                    "输出 {}",
                    values(ch, "outputChannels")
                        .iter()
                        .map(|v| v.to_string())
                        .collect::<Vec<_>>()
                        .join("、")
                )
            };
            let muted_cmd = json!({"action":"set","scope":"channel","role":ROLES[i],"field":"muted","value":!flag(ch,"muted")});
            let solo_cmd = json!({"action":"set","scope":"channel","role":ROLES[i],"field":"solo","value":!flag(ch,"solo")});
            cards.push(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .p_2()
                    .rounded_lg()
                    .border_1()
                    .border_color(if selected { accent } else { cx.theme().border })
                    .bg(if selected {
                        accent.opacity(0.08)
                    } else {
                        cx.theme().background
                    })
                    .child(
                        self.cmd_button(
                            format!("ch{i}"),
                            NAMES[i],
                            json!({"action":"ui","kind":"role","index":i}),
                            cx,
                        )
                        .ghost()
                        .w_full()
                        .text_color(accent),
                    )
                    .child(label(device, cx))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .font_family("Menlo")
                                    .text_sm()
                                    .child(format!("{:+.1} dB", number(ch, "gainDB"))),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(cx.theme().muted_foreground)
                                    .child(db),
                            ),
                    )
                    .child(
                        div()
                            .h(px(3.))
                            .w_full()
                            .rounded_full()
                            .bg(cx.theme().border)
                            .child(
                                div()
                                    .h_full()
                                    .w(relative(
                                        ((20. * peak.max(1e-6).log10() + 60.) / 60.).clamp(0., 1.)
                                            as f32,
                                    ))
                                    .rounded_full()
                                    .bg(accent),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                self.cmd_button(format!("mute{i}"), "静音", muted_cmd, cx)
                                    .selected(flag(ch, "muted"))
                                    .flex_1(),
                            )
                            .child(
                                self.cmd_button(format!("solo{i}"), "独听", solo_cmd, cx)
                                    .selected(flag(ch, "solo"))
                                    .flex_1(),
                            ),
                    )
                    .child(label(status, cx))
                    .into_any_element(),
            );
        }
        div()
            .id("sidebar-scroll")
            .overflow_y_scroll()
            .w(px(194.))
            .flex_shrink_0()
            .h_full()
            .min_h_0()
            .border_r_1()
            .border_color(cx.theme().border)
            .p_3()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_xs()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(cx.theme().muted_foreground)
                    .child("输出声道  /  L + R → MONO"),
            )
            .children(cards)
            .child(div().flex_1())
            .when(any_solo, |el| {
                el.child(self.cmd_button(
                    "cancel-solo",
                    "取消全部独听",
                    json!({"action":"clearSolos"}),
                    cx,
                ))
            })
            .children(
                ["调音", "设备与测量", "音箱配置"]
                    .iter()
                    .enumerate()
                    .map(|(index, name)| {
                        self.cmd_button(
                            format!("page{index}"),
                            *name,
                            json!({"action":"ui","kind":"page","index":index}),
                            cx,
                        )
                        .selected(self.page == index)
                        .w_full()
                    }),
            )
            .child(label("⌘1 / ⌘2 / ⌘3 切换声道", cx))
    }
    fn controls(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let ch = self.channel();
        let gain = self.numeric(
            "gainDB",
            number(&ch, "gainDB"),
            (-60., 12.),
            "dB",
            110.,
            window,
            cx,
        );
        let delay = self.numeric(
            "delayMS",
            number(&ch, "delayMS"),
            (0., 2000.),
            "ms",
            124.,
            window,
            cx,
        );
        let frames = (number(&ch, "delayMS") * number(&self.data, "sampleRate") / 1000.).round();
        let actual = frames * 1000. / number(&self.data, "sampleRate").max(1.);
        let muted = self.comparing();
        panel(cx)
            .flex_row()
            .items_center()
            .justify_between()
            .py_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(color(self.role, cx.theme().mode.is_dark()))
                            .child(NAMES[self.role]),
                    )
                    .child(
                        self.cmd_button(
                            "enabled",
                            if flag(&ch, "enabled") {
                                "已启用"
                            } else {
                                "已关闭"
                            },
                            self.setting("channel", "enabled", json!(!flag(&ch, "enabled")), None),
                            cx,
                        )
                        .selected(flag(&ch, "enabled"))
                        .disabled(muted),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(label("音量", cx))
                    .child(
                        self.cmd_button(
                            "gain-",
                            "−",
                            self.setting(
                                "channel",
                                "gainDB",
                                json!((number(&ch, "gainDB") - 0.5).max(-60.)),
                                None,
                            ),
                            cx,
                        )
                        .disabled(muted),
                    )
                    .child(gain)
                    .child(
                        self.cmd_button(
                            "gain+",
                            "+",
                            self.setting(
                                "channel",
                                "gainDB",
                                json!((number(&ch, "gainDB") + 0.5).min(12.)),
                                None,
                            ),
                            cx,
                        )
                        .disabled(muted),
                    ),
            )
            .child(
                self.cmd_button(
                    "polarity",
                    "极性反转",
                    self.setting("channel", "inverted", json!(!flag(&ch, "inverted")), None),
                    cx,
                )
                .selected(flag(&ch, "inverted"))
                .disabled(muted),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(label("延迟", cx))
                    .child(delay)
                    .child(label(format!("{frames:.0} 点\n{actual:.3} ms"), cx)),
            )
    }
    fn crossover(
        &mut self,
        which: &str,
        title: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let ch = self.channel();
        let filter = ch[which].clone();
        let disabled = self.comparing();
        let frequency = self.numeric(
            &format!("{which}.frequency"),
            number(&filter, "frequency"),
            (1., 96000.),
            "Hz",
            126.,
            window,
            cx,
        );
        let entries = SHAPES
            .iter()
            .map(|(key, title)| {
                (
                    title.to_string(),
                    self.setting("channel", &format!("{which}.shape"), json!(key), None),
                )
            })
            .collect();
        let shape = SHAPES
            .iter()
            .find(|(key, _)| *key == text(&filter, "shape"))
            .map(|(_, title)| *title)
            .unwrap_or("选择滤波器");
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        self.cmd_button(
                            format!("toggle-{which}"),
                            format!(
                                "{} {}",
                                if flag(&filter, "enabled") {
                                    "●"
                                } else {
                                    "○"
                                },
                                title
                            ),
                            self.setting(
                                "channel",
                                &format!("{which}.enabled"),
                                json!(!flag(&filter, "enabled")),
                                None,
                            ),
                            cx,
                        )
                        .ghost()
                        .disabled(disabled),
                    )
                    .child(frequency),
            )
            .child(self.menu_button(format!("shape-{which}"), format!("{shape} ▾"), entries, cx))
            .child(label(
                if which == "highPass" {
                    "削减低于截止频率的声音"
                } else {
                    "削减高于截止频率的声音"
                },
                cx,
            ))
            .when(
                number(&filter, "frequency") >= number(&self.data, "sampleRate") / 2.,
                |el| {
                    el.child(
                        div()
                            .text_xs()
                            .text_color(rgb(0xba6b28))
                            .child("频率超出当前采样率范围"),
                    )
                },
            )
    }
    fn tuning(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let high = self.crossover("highPass", "高通", window, cx);
        let low = self.crossover("lowPass", "低通", window, cx);
        let eq = self.equalizer(window, cx);
        div()
            .flex()
            .flex_1()
            .min_h_0()
            .gap_3()
            .child(
                panel(cx)
                    .w(px(232.))
                    .flex_shrink_0()
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("分频滤波"))
                    .child(
                        div()
                            .id("crossover-scroll")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap_4()
                            .child(high)
                            .child(div().h(px(1.)).bg(cx.theme().border))
                            .child(low),
                    )
                    .child(
                        self.cmd_button(
                            "pair",
                            "左右配对分频…",
                            json!({"action":"ui","kind":"pair"}),
                            cx,
                        )
                        .disabled(self.comparing()),
                    ),
            )
            .child(eq)
    }
    fn eq_table(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let ch = self.channel();
        let bands = values(&ch, "bands");
        let disabled = self.comparing();
        let mut rows = vec![];
        for (index, band) in bands.iter().enumerate() {
            let id = text(band, "id");
            let selected = self.selected_band == id;
            let mut fields = vec![];
            for (field, width, range, step) in [
                ("frequency", 100., (1., 96000.), 1.),
                ("gainDB", 82., (-30., 30.), 0.1),
                ("q", 74., (0.05, 100.), 0.01),
            ] {
                let cmd = self.setting("band", field, band[field].clone(), Some(&id));
                let input = self.input(
                    format!(
                        "{}/{}/eq/{id}/{field}",
                        text(&self.data["profile"], "id"),
                        self.role
                    ),
                    format_num(number(band, field)),
                    cmd,
                    Some(range),
                    step,
                    disabled
                        || (field == "gainDB"
                            && ["highPass", "lowPass"].contains(&text(band, "kind").as_str())),
                    window,
                    cx,
                );
                fields.push(
                    div()
                        .w(px(width))
                        .flex_shrink_0()
                        .child(input)
                        .into_any_element(),
                );
            }
            let kind_title = KINDS
                .iter()
                .find(|(key, _)| *key == text(band, "kind"))
                .map(|(_, title)| *title)
                .unwrap_or("峰值");
            let entries = KINDS
                .iter()
                .map(|(kind, title)| {
                    (
                        title.to_string(),
                        self.setting("band", "kind", json!(kind), Some(&id)),
                    )
                })
                .collect();
            rows.push(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .bg(if selected {
                        color(self.role, cx.theme().mode.is_dark()).opacity(0.10)
                    } else {
                        cx.theme().transparent
                    })
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                self.cmd_button(
                                    format!("num{id}"),
                                    format!("{}", index + 1),
                                    json!({"action":"ui","kind":"band","id":id}),
                                    cx,
                                )
                                .ghost()
                                .w(px(25.)),
                            )
                            .child(
                                self.cmd_button(
                                    format!("on{id}"),
                                    if flag(band, "enabled") { "●" } else { "○" },
                                    self.setting(
                                        "band",
                                        "enabled",
                                        json!(!flag(band, "enabled")),
                                        Some(&id),
                                    ),
                                    cx,
                                )
                                .ghost()
                                .disabled(disabled)
                                .w(px(24.)),
                            )
                            .child(div().flex_1().min_w(px(64.)).child(self.menu_button(
                                format!("kind{id}"),
                                format!("{kind_title} ▾"),
                                entries,
                                cx,
                            )))
                            .children(fields)
                            .child(
                                self.cmd_button(
                                    format!("del{id}"),
                                    "−",
                                    json!({"action":"removeBand","role":ROLES[self.role],"id":id}),
                                    cx,
                                )
                                .ghost()
                                .disabled(disabled),
                            ),
                    )
                    .when(
                        number(band, "frequency") >= number(&self.data, "sampleRate") / 2.,
                        |el| {
                            el.child(div().text_xs().text_color(rgb(0xba6b28)).child(format!(
                                "EQ {} 须低于 {:.0} Hz",
                                index + 1,
                                number(&self.data, "sampleRate") / 2.
                            )))
                        },
                    )
                    .into_any_element(),
            );
        }
        let preamp = self.numeric(
            "preampDB",
            number(&ch, "preampDB"),
            (-60., 12.),
            "dB",
            100.,
            window,
            cx,
        );
        let mut operations = vec![
            (
                "所有增益归零".into(),
                json!({"action":"flatEQ","role":ROLES[self.role]}),
            ),
            (
                "清空 EQ".into(),
                json!({"action":"clearEQ","role":ROLES[self.role]}),
            ),
        ];
        if !self.selected_band.is_empty() && bands.len() < 20 {
            operations.insert(0,("复制所选滤波器".into(),json!({"action":"duplicateBand","role":ROLES[self.role],"id":self.selected_band})));
        }
        for i in 0..3 {
            if i != self.role {
                operations.push((
                    format!("从{}复制 EQ", NAMES[i]),
                    json!({"action":"copyEQ","role":ROLES[self.role],"source":ROLES[i]}),
                ));
            }
        }
        div()
            .flex()
            .flex_col()
            .gap_2()
            .flex_1()
            .min_w_0()
            .min_h_0()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        self.cmd_button(
                            "eq-toggle",
                            if flag(&ch, "eqEnabled") {
                                "参数 EQ"
                            } else {
                                "参数 EQ · 已旁路"
                            },
                            self.setting(
                                "channel",
                                "eqEnabled",
                                json!(!flag(&ch, "eqEnabled")),
                                None,
                            ),
                            cx,
                        )
                        .selected(flag(&ch, "eqEnabled"))
                        .disabled(disabled),
                    )
                    .child(label(format!("{}/20", bands.len()), cx))
                    .child(div().flex_1())
                    .child(self.menu_button("eq-ops", "操作 ▾", operations, cx))
                    .child(
                        self.cmd_button(
                            "import-eq",
                            "导入 REW…",
                            json!({"action":"importEQ","role":ROLES[self.role]}),
                            cx,
                        )
                        .disabled(disabled),
                    )
                    .child(
                        self.cmd_button(
                            "add-eq",
                            "+ 添加",
                            json!({"action":"addBand","role":ROLES[self.role]}),
                            cx,
                        )
                        .disabled(disabled || bands.len() >= 20),
                    ),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .px_2()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(div().w(px(57.)).child("# / 开"))
                    .child(div().flex_1().child("类型"))
                    .child(div().w(px(100.)).child("频率 · Hz"))
                    .child(div().w(px(82.)).child("增益 · dB"))
                    .child(div().w(px(74.)).child("Q"))
                    .child(div().w(px(24.))),
            )
            .child(
                div()
                    .id("eq-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .children(rows)
                    .when(bands.is_empty(), |el| {
                        el.child(
                            div()
                                .size_full()
                                .flex()
                                .flex_col()
                                .items_center()
                                .justify_center()
                                .gap_3()
                                .py_4()
                                .child(label("EQ 平直，从一个滤波器开始", cx))
                                .child(
                                    self.cmd_button(
                                        "first-eq",
                                        "添加滤波器",
                                        json!({"action":"addBand","role":ROLES[self.role]}),
                                        cx,
                                    )
                                    .primary()
                                    .disabled(disabled),
                                ),
                        )
                    }),
            )
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .pt_2()
                    .border_t_1()
                    .border_color(cx.theme().border)
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(label("EQ 前级", cx))
                            .child(preamp),
                    )
                    .child(label("回车应用 · ↑↓ 微调 · ⌘Z 撤销", cx)),
            )
    }
    fn routing(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let ch = self.channel();
        let devices = values(&self.data, "devices");
        let device = devices
            .iter()
            .find(|d| d["uid"] == ch["deviceUID"])
            .cloned()
            .unwrap_or(json!({}));
        let choices = devices
            .iter()
            .map(|d| {
                (
                    text(d, "name"),
                    self.setting("channel", "deviceUID", d["uid"].clone(), None),
                )
            })
            .collect();
        let mut outputs = vec![];
        for n in 1..=number(&device, "channels") as i32 {
            let mut selected: Vec<i32> = values(&ch, "outputChannels")
                .iter()
                .filter_map(|v| v.as_i64().map(|x| x as i32))
                .collect();
            let checked = selected.contains(&n);
            if checked {
                selected.retain(|i| *i != n);
            } else {
                selected.push(n);
            }
            selected.sort();
            outputs.push(
                self.cmd_button(
                    format!("output{n}"),
                    format!("通道 {n}"),
                    self.setting("channel", "outputChannels", json!(selected), None),
                    cx,
                )
                .selected(checked)
                .disabled(self.comparing())
                .into_any_element(),
            );
        }
        let mut refs = vec![];
        for r in values(&ch, "measurements") {
            let id = text(&r, "id");
            let cmd = self.setting("measurement", "offsetDB", r["offsetDB"].clone(), Some(&id));
            let input = self.input(
                format!("ref{id}"),
                format_num(number(&r, "offsetDB")),
                cmd,
                Some((-150., 150.)),
                0.1,
                self.comparing(),
                window,
                cx,
            );
            refs.push(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .p_3()
                    .border_1()
                    .border_color(cx.theme().border)
                    .rounded_md()
                    .child(
                        div()
                            .flex_1()
                            .child(
                                self.cmd_button(
                                    format!("ref-visible{id}"),
                                    format!(
                                        "{} {}",
                                        if flag(&r, "visible") { "●" } else { "○" },
                                        text(&r, "name")
                                    ),
                                    self.setting(
                                        "measurement",
                                        "visible",
                                        json!(!flag(&r, "visible")),
                                        Some(&id),
                                    ),
                                    cx,
                                )
                                .ghost(),
                            )
                            .child(label(text(&r, "source"), cx)),
                    )
                    .child(label("偏移 dB", cx))
                    .child(div().w(px(90.)).child(input))
                    .child(
                        self.cmd_button(
                            format!("ref-del{id}"),
                            "移除",
                            json!({"action":"removeMeasurement","role":ROLES[self.role],"id":id}),
                            cx,
                        )
                        .ghost(),
                    )
                    .into_any_element(),
            );
        }
        div()
            .flex()
            .gap_3()
            .flex_1()
            .min_h_0()
            .child(
                panel(cx)
                    .w(px(300.))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("输出设备"))
                    .child(self.menu_button(
                        "device",
                        if device.is_object() && !text(&device, "name").is_empty() {
                            format!("{} ▾", text(&device, "name"))
                        } else {
                            "选择设备 ▾".into()
                        },
                        choices,
                        cx,
                    ))
                    .child(label(
                        format!(
                            "{:.0} 个独立输出 · {:.1} kHz",
                            number(&device, "channels"),
                            number(&device, "sampleRate") / 1000.
                        ),
                        cx,
                    ))
                    .child(label("软件独立控制的路数由设备通道决定", cx))
                    .child(div().flex().flex_wrap().gap_2().children(outputs))
                    .child(div().h(px(1.)).bg(cx.theme().border))
                    .children(
                        values(&self.data, "routes")
                            .iter()
                            .map(|v| label(v.as_str().unwrap_or("").to_string(), cx)),
                    ),
            )
            .child(
                panel(cx)
                    .flex_1()
                    .min_w_0()
                    .child(
                        div()
                            .flex()
                            .justify_between()
                            .items_center()
                            .child(
                                div()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("REW 测量参考"),
                            )
                            .child(
                                self.cmd_button(
                                    "import-measurement",
                                    "导入测量…",
                                    json!({"action":"importMeasurement","role":ROLES[self.role]}),
                                    cx,
                                )
                                .disabled(self.comparing()),
                            ),
                    )
                    .child(
                        div()
                            .id("refs")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .children(refs)
                            .when(values(&ch, "measurements").is_empty(), |el| {
                                el.child(label(
                                    "导入频率、SPL 与可选相位文本，叠加查看实际测量。",
                                    cx,
                                ))
                            }),
                    ),
            )
    }
    fn profiles(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let mut rows = vec![];
        for p in values(&self.data, "profiles") {
            rows.push(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .p_4()
                    .rounded_md()
                    .border_1()
                    .border_color(cx.theme().border)
                    .child(
                        div()
                            .font_weight(FontWeight::MEDIUM)
                            .child(text(&p, "name")),
                    )
                    .child(
                        self.cmd_button(
                            format!("profile{}", text(&p, "id")),
                            if p["id"] == self.data["profile"]["id"] {
                                "当前配置"
                            } else {
                                "切换配置"
                            },
                            json!({"action":"selectProfile","id":p["id"]}),
                            cx,
                        )
                        .disabled(p["id"] == self.data["profile"]["id"]),
                    )
                    .into_any_element(),
            );
        }
        panel(cx)
            .flex_1()
            .min_h_0()
            .child(div().font_weight(FontWeight::SEMIBOLD).child("音箱配置"))
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(self.cmd_button(
                        "new-profile",
                        "新建",
                        json!({"action":"newProfile"}),
                        cx,
                    ))
                    .child(self.cmd_button(
                        "copy-profile",
                        "复制当前",
                        json!({"action":"duplicateProfile"}),
                        cx,
                    ))
                    .child(self.cmd_button(
                        "rename-profile",
                        "重命名",
                        json!({"action":"ui","kind":"modal","value":"rename"}),
                        cx,
                    ))
                    .child(
                        self.cmd_button(
                            "delete-profile",
                            "删除",
                            json!({"action":"ui","kind":"modal","value":"delete"}),
                            cx,
                        )
                        .disabled(values(&self.data, "profiles").len() < 2),
                    )
                    .child(self.cmd_button(
                        "import-profile",
                        "导入 JSON…",
                        json!({"action":"importProfile"}),
                        cx,
                    ))
                    .child(self.cmd_button(
                        "export-profile",
                        "导出…",
                        json!({"action":"exportProfile"}),
                        cx,
                    )),
            )
            .child(
                div()
                    .id("profile-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .children(rows),
            )
            .child(label("修改自动保存；快照与撤销历史保留在本次会话中。", cx))
    }
    fn footer(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let p = self.data["profile"].clone();
        let master = self.input(
            "master-gain".into(),
            format_num(number(&p, "masterGainDB")),
            self.setting("master", "gain", p["masterGainDB"].clone(), None),
            Some((-60., 12.)),
            0.1,
            false,
            window,
            cx,
        );
        let pre = self.input(
            "master-preamp".into(),
            format_num(number(&p, "preampDB")),
            self.setting("master", "preamp", p["preampDB"].clone(), None),
            Some((-60., 0.)),
            0.1,
            false,
            window,
            cx,
        );
        let peak = number(&self.data, "inputPeak");
        let readout = if peak > 1e-6 {
            format!("输入 {:.1} dBFS", 20. * peak.log10())
        } else {
            "输入 −∞ dBFS".into()
        };
        div()
            .flex()
            .items_center()
            .justify_between()
            .px_5()
            .h(px(52.))
            .flex_shrink_0()
            .bg(cx.theme().background)
            .border_t_1()
            .border_color(cx.theme().border)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .size(px(7.))
                            .rounded_full()
                            .bg(if flag(&self.data, "running") {
                                rgb(0x269f78)
                            } else {
                                rgb(0x8893a0)
                            }),
                    )
                    .child(label(text(&self.data, "status"), cx))
                    .child(label(
                        format!("{:.1} kHz", number(&self.data, "sampleRate") / 1000.),
                        cx,
                    ))
                    .child(label(readout, cx))
                    .child(label(
                        format!("限幅 {:.1} dB", number(&self.data, "reduction")),
                        cx,
                    )),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(label("前级 dB", cx))
                    .child(div().w(px(78.)).child(pre))
                    .child(label("总音量 dB", cx))
                    .child(div().w(px(84.)).child(master))
                    .child(
                        self.cmd_button(
                            "master-mute",
                            "总静音",
                            self.setting("master", "muted", json!(!flag(&p, "masterMuted")), None),
                            cx,
                        )
                        .selected(flag(&p, "masterMuted")),
                    ),
            )
    }
    fn graph(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let channels = values(&self.data["display"], "channels");
        let rate = number(&self.data, "sampleRate").max(8000.);
        let upper = 20000f64.min(rate * 0.499);
        let master = if self.include_master {
            number(&self.data["display"], "masterGainDB")
                + number(&self.data["display"], "preampDB")
        } else {
            0.
        };
        let height = (f32::from(window.viewport_size().height) - 700.).clamp(105., 200.);
        let phase = self.phase;
        let role = self.role;
        let selected = self.selected_band.clone();
        let dark = cx.theme().mode.is_dark();
        let text_color = cx.theme().muted_foreground;
        let border = cx.theme().border;
        let node_text = cx.theme().background;
        let any_solo = channels
            .iter()
            .any(|c| flag(c, "solo") && flag(c, "enabled"));
        let master_muted = flag(&self.data["display"], "masterMuted");
        let hover = self.hover;
        let bounds_cache = self.plot_bounds.clone();
        let spl_min = self.spl_min;
        let spl_max = self.spl_max;
        let channel = self.channel();
        let comparing = self.comparing();
        let mut legend = vec![];
        for (i, ch) in channels.iter().enumerate().take(3) {
            legend.push(self.cmd_button(format!("curve{i}"),SYMBOLS[i],json!({"action":"set","scope":"channel","role":ROLES[i],"field":"showCurve","value":!flag(ch,"showCurve")}),cx).selected(flag(ch,"showCurve")).text_color(color(i,dark)).into_any_element());
        }
        let compare_exists = values(&self.data, "comparisons")
            .iter()
            .any(|v| v.as_str() == Some(ROLES[self.role]));
        let plot=div().id("response-plot").relative().h(px(height)).w_full().cursor(CursorStyle::Crosshair)
            .child(canvas(move|bounds,_,_|{bounds_cache.set(bounds);},move|bounds,_,window,cx|{
                let g=PlotGeometry::new(bounds,upper,phase);
                for frequency in [20.,50.,100.,200.,500.,1000.,2000.,5000.,10000.,20000.] {
                    if frequency>upper {continue;}
                    stroke(&[point(g.x(frequency),g.top),point(g.x(frequency),g.bottom)],border.opacity(0.65),0.7,window);
                    let text=if frequency>=1000.{format!("{}k",frequency/1000.)}else{format!("{frequency}")};
                    paint_text(&text,point(g.x(frequency)-px(9.),g.bottom+px(8.)),text_color,window,cx);
                }
                let ticks=if phase{vec![-180.,-90.,0.,90.,180.]}else{vec![-60.,-36.,-12.,0.,12.,24.]};
                for value in ticks {
                    stroke(&[point(g.left,g.y(value)),point(g.right,g.y(value))],if value==0.{text_color.opacity(0.5)}else{border.opacity(0.65)},if value==0.{1.}else{0.7},window);
                    paint_text(&format!("{value}"),point(bounds.left()+px(2.),g.y(value)-px(5.)),text_color,window,cx);
                }
                let has_measurement=channels.iter().any(|c|!values(c,"measurements").is_empty());
                if has_measurement && !phase {
                    for t in [0.,0.5,1.] {paint_text(&format!("{:.0}",spl_min+(spl_max-spl_min)*t),point(g.right+px(4.),g.bottom-px(f32::from(g.bottom-g.top)*t as f32)-px(5.)),text_color,window,cx);}
                }
                for (i,ch) in channels.iter().enumerate().take(3) {
                    if !flag(ch,"showCurve"){continue;}
                    let audible=flag(ch,"enabled")&&!flag(ch,"muted")&&(!any_solo||flag(ch,"solo"))&&!master_muted;
                    let ink=color(i,dark).opacity(if !audible{0.25}else if i==role{1.}else{0.6});
                    let mut points=vec![];let mut last=None;
                    for n in 0..640 {
                        let frequency=20.*(upper/20.).powf(n as f64/639.);let (db,p)=response(ch,frequency,rate,master);let value=if phase{p}else{db};
                        if phase && last.is_some_and(|v:f64|(value-v).abs()>180.) {stroke(&points,ink,if i==role{2.2}else{1.4},window);points.clear();}
                        points.push(point(g.x(frequency),g.y(value.clamp(g.low,g.high))));last=Some(value);
                    }
                    stroke(&points,ink,if i==role{2.2}else{1.4},window);
                    for reference in values(ch,"measurements").iter().filter(|r|flag(r,"visible")) {
                        let mut points=vec![];let mut last=None;
                        for p in values(reference,"plotPoints") {
                            let f=p[0].as_f64().unwrap_or(20.);let y=if phase{if p[3].as_i64()!=Some(1)&&p[3].as_f64()!=Some(1.){continue;}let p=p[2].as_f64().unwrap_or(0.).to_radians();p.sin().atan2(p.cos()).to_degrees()}else{p[1].as_f64().unwrap_or(0.)+number(reference,"offsetDB")};
                            if phase && last.is_some_and(|v:f64|(y-v).abs()>180.) {stroke_dashed(&points,color(i,dark).opacity(0.5),window);points.clear();}
                            points.push(point(g.x(f),if phase{g.y(y)}else{g.bottom-px(((y-spl_min)/(spl_max-spl_min).max(1.)*f64::from(f32::from(g.bottom-g.top))) as f32)}));last=Some(y);
                        }
                        stroke_dashed(&points,color(i,dark).opacity(0.5),window);
                    }
                    if i==role&&!phase&&flag(ch,"eqEnabled") {
                        let bands=values(ch,"bands");let mut nodes:Vec<_>=bands.iter().enumerate().filter(|(_,b)|flag(b,"enabled")&&(20.0..=upper).contains(&number(b,"frequency"))).collect();
                        nodes.sort_by_key(|(_,b)|text(b,"id")==selected);
                        for (index,band) in nodes {
                            let f=number(band,"frequency");let (db,_)=response(ch,f,rate,master);if !(g.low..=g.high).contains(&db){continue;}
                            let pos=point(g.x(f),g.y(db));let is_selected=text(band,"id")==selected;let accent=color(i,dark);
                            window.paint_quad(quad(Bounds::new(pos-point(px(8.),px(8.)),size(px(16.),px(16.))),px(8.),if is_selected{accent}else{node_text},px(1.3),accent,Default::default()));
                            paint_text(&format!("{}",index+1),pos-point(px(if index<9{3.}else{6.}),px(6.)),if is_selected{node_text}else{accent},window,cx);
                        }
                    }
                }
                if let Some(f)=hover {stroke_dashed(&[point(g.x(f),g.top),point(g.x(f),g.bottom)],text_color.opacity(0.45),window);}
            }).size_full())
            .on_mouse_down(MouseButton::Left,cx.listener(move|this,event:&MouseDownEvent,_,cx|{
                if this.phase||this.comparing(){return;}
                let g=PlotGeometry::new(this.plot_bounds.get(),upper,false);let ch=this.channel();
                if !flag(&ch,"eqEnabled")||!flag(&ch,"showCurve"){return;}
                let mut candidates:Vec<_>=values(&ch,"bands").into_iter().filter(|b|flag(b,"enabled")).map(|band|{let f=number(&band,"frequency");let db=response(&ch,f,rate,master).0;let distance=(f32::from(g.x(f)-event.position.x)).hypot(f32::from(g.y(db)-event.position.y));(distance,band)}).filter(|(distance,_)|*distance<15.).collect();
                candidates.sort_by(|a,b|a.0.total_cmp(&b.0).then_with(||(text(&a.1,"id")!=this.selected_band).cmp(&(text(&b.1,"id")!=this.selected_band))));
                if let Some((_,band))=candidates.first(){this.dragging=text(band,"id");this.selected_band=this.dragging.clone();native::send(&json!({"action":"beginGesture"}));cx.notify();}
            }))
            .on_mouse_move(cx.listener(move|this,event:&MouseMoveEvent,window,cx|{
                let g=PlotGeometry::new(this.plot_bounds.get(),upper,this.phase);let f=g.frequency(event.position.x);this.hover=Some(f);
                if !this.dragging.is_empty() && event.dragging() && !this.comparing() {
                    let ch=this.channel();if let Some(band)=values(&ch,"bands").iter().find(|b|text(b,"id")==this.dragging) {
                        let frequency=(f*10.).round()/10.;let db=response(&ch,frequency,rate,master).0;
                        let contribution=response(&json!({"coefficients":[band["coefficient"].clone()]}),frequency,rate,0.).0;
                        let kind=text(band,"kind");let has_gain=kind!="highPass"&&kind!="lowPass";
                        let gain=if has_gain{((g.value(event.position.y)-(db-contribution))/if kind=="peak"{1.}else{0.5}).clamp(-30.,30.)}else{number(band,"gainDB")};
                        native::send(&json!({"action":"editBand","role":ROLES[this.role],"id":this.dragging,"frequency":frequency,"gainDB":(gain*10.).round()/10.}));this.pull(window,cx);
                    }
                }
                cx.notify();
            }))
            .on_mouse_up(MouseButton::Left,cx.listener(|this,_,_,cx|{this.finish_drag();cx.notify();}))
            .on_mouse_up_out(MouseButton::Left,cx.listener(|this,_,_,cx|{this.finish_drag();cx.notify();}));
        let hover_readout = self
            .hover
            .map(|f| {
                let (db, phase) = response(&channel, f, rate, master);
                format!(
                    "{f:.1} Hz   {:+.1} {}",
                    if self.phase { phase } else { db },
                    if self.phase { "°" } else { "dB" }
                )
            })
            .unwrap_or_else(|| "拖动编号控制点调整频率与增益".into());
        let mut scales = vec![];
        if values(&channel, "measurements").len() > 0 && !self.phase {
            let lo = self.input(
                "spl-min".into(),
                format_num(self.spl_min),
                json!({"action":"local","field":"splMin"}),
                Some((-150., self.spl_max - 1.)),
                1.,
                false,
                window,
                cx,
            );
            let hi = self.input(
                "spl-max".into(),
                format_num(self.spl_max),
                json!({"action":"local","field":"splMax"}),
                Some((self.spl_min + 1., 200.)),
                1.,
                false,
                window,
                cx,
            );
            scales.push(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(label("SPL 右轴", cx))
                    .child(div().w(px(66.)).child(lo))
                    .child(label("—", cx))
                    .child(div().w(px(66.)).child(hi))
                    .into_any_element(),
            );
        }
        panel(cx)
            .gap_2()
            .flex_shrink_0()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(if self.phase {
                                "相位响应"
                            } else {
                                "频率响应"
                            }),
                    )
                    .child(div().flex_1())
                    .child(
                        self.cmd_button(
                            "phase",
                            if self.phase {
                                "频响视图"
                            } else {
                                "相位视图"
                            },
                            json!({"action":"ui","kind":"phase"}),
                            cx,
                        )
                        .ghost(),
                    )
                    .child(
                        self.cmd_button(
                            "include-master",
                            "计入总增益",
                            json!({"action":"ui","kind":"master"}),
                            cx,
                        )
                        .selected(self.include_master)
                        .ghost(),
                    )
                    .child(
                        self.cmd_button(
                            "capture",
                            "存快照",
                            json!({"action":"capture","role":ROLES[self.role]}),
                            cx,
                        )
                        .disabled(comparing),
                    )
                    .child(
                        self.cmd_button(
                            "compare",
                            if comparing {
                                "返回编辑"
                            } else {
                                "对比快照"
                            },
                            json!({"action":"compare","role":ROLES[self.role]}),
                            cx,
                        )
                        .selected(comparing)
                        .disabled(!compare_exists),
                    )
                    .children(legend),
            )
            .child(plot)
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(label(
                        if comparing {
                            "正在使用已保存快照 · 参数只读".into()
                        } else {
                            hover_readout
                        },
                        cx,
                    ))
                    .children(scales),
            )
    }
    fn finish_drag(&mut self) {
        if !self.dragging.is_empty() {
            native::send(&json!({"action":"endGesture"}));
            self.dragging.clear();
        }
    }
    fn overlay(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let preview = self.data.get("preview").cloned();
        if self.modal.is_empty() && preview.is_none() {
            return None;
        }
        let title = if preview.is_some() {
            "导入 REW 参数"
        } else {
            match self.modal.as_str() {
                "pair" => "左右配对分频",
                "rename" => "重命名配置",
                "delete" => "删除音箱配置",
                "preset-save" => "保存 EQ 预设",
                "preset-rename" => "重命名 EQ 预设",
                "preset-delete" => "删除 EQ 预设",
                "graphic-confirm" => "转换为 10 段均衡器",
                _ => "接线与调音",
            }
        };
        let mut content = vec![];
        let mut buttons = vec![];
        if let Some(preview) = preview {
            content.push(
                label(
                    format!(
                        "{} · 前级 {:.2} dB",
                        text(&preview, "source"),
                        number(&preview, "preampDB")
                    ),
                    cx,
                )
                .into_any_element(),
            );
            for (i, b) in values(&preview, "bands").iter().enumerate() {
                content.push(
                    div()
                        .font_family("Menlo")
                        .text_sm()
                        .child(format!(
                            "{}  {}  {}  {:.1} Hz  {:+.2} dB  Q {:.3}",
                            i + 1,
                            if flag(b, "enabled") { "ON " } else { "OFF" },
                            text(b, "kind"),
                            number(b, "frequency"),
                            number(b, "gainDB"),
                            number(b, "q")
                        ))
                        .into_any_element(),
                );
            }
            for issue in values(&preview, "issues") {
                content.push(
                    div()
                        .text_sm()
                        .text_color(rgb(0xb76b22))
                        .child(issue.as_str().unwrap_or("").to_string())
                        .into_any_element(),
                );
            }
            content.push(
                label("应用会替换目标声道的 EQ 列表和 EQ 前级，可用 ⌘Z 撤销。", cx)
                    .into_any_element(),
            );
            buttons.push(
                self.cmd_button("cancel-preview", "取消", json!({"action":"cancelEQ"}), cx)
                    .into_any_element(),
            );
            buttons.push(
                self.cmd_button("apply-preview", "应用参数", json!({"action":"applyEQ"}), cx)
                    .primary()
                    .disabled(!flag(&preview, "canApply"))
                    .into_any_element(),
            );
        } else if self.modal == "pair" {
            content.push(
                label("为左右声道选择频段分配；两路均可连接任意类型的音箱。", cx)
                    .into_any_element(),
            );
            content.push(
                div()
                    .flex()
                    .gap_3()
                    .child(
                        self.cmd_button(
                            "pair-left",
                            "左低通 / 右高通",
                            json!({"action":"ui","kind":"pairRole","index":0}),
                            cx,
                        )
                        .selected(self.pair_role == 0),
                    )
                    .child(
                        self.cmd_button(
                            "pair-right",
                            "左高通 / 右低通",
                            json!({"action":"ui","kind":"pairRole","index":1}),
                            cx,
                        )
                        .selected(self.pair_role == 1),
                    )
                    .into_any_element(),
            );
            let frequency = self.input(
                "modal-pair".into(),
                format_num(self.pair_frequency),
                json!({"action":"local","field":"pair"}),
                Some((20., 20000f64.min(number(&self.data, "sampleRate") * 0.499))),
                1.,
                false,
                window,
                cx,
            );
            content.push(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(label("分频点 · Hz", cx))
                    .child(div().w(px(150.)).child(frequency))
                    .into_any_element(),
            );
            content.push(
                div()
                    .flex()
                    .gap_3()
                    .child(
                        self.cmd_button(
                            "lr24",
                            "LR · 24 dB/oct",
                            json!({"action":"ui","kind":"pairShape","value":"linkwitzRiley24"}),
                            cx,
                        )
                        .selected(self.pair_shape == "linkwitzRiley24"),
                    )
                    .child(
                        self.cmd_button(
                            "lr48",
                            "LR · 48 dB/oct",
                            json!({"action":"ui","kind":"pairShape","value":"linkwitzRiley48"}),
                            cx,
                        )
                        .selected(self.pair_shape == "linkwitzRiley48"),
                    )
                    .into_any_element(),
            );
            content.push(label("应用会替换左右高低通开关及所用分频参数。EQ、音量、极性与延迟保留；分频点须根据音箱和测量决定。",cx).into_any_element());
            buttons.push(
                self.cmd_button(
                    "cancel-pair",
                    "取消",
                    json!({"action":"ui","kind":"close"}),
                    cx,
                )
                .into_any_element(),
            );
            buttons.push(
                self.cmd_button(
                    "apply-pair",
                    "应用左右分频",
                    json!({"action":"ui","kind":"applyPair"}),
                    cx,
                )
                .primary()
                .disabled(!self.error.is_empty())
                .into_any_element(),
            );
        } else if self.modal == "rename" {
            let input = self.input(
                "modal-name".into(),
                self.draft.clone(),
                json!({"action":"local","field":"rename"}),
                None,
                1.,
                false,
                window,
                cx,
            );
            content.push(input.into_any_element());
            buttons.push(
                self.cmd_button(
                    "cancel-rename",
                    "取消",
                    json!({"action":"ui","kind":"close"}),
                    cx,
                )
                .into_any_element(),
            );
            buttons.push(
                self.cmd_button(
                    "apply-rename",
                    "保存",
                    json!({"action":"ui","kind":"rename"}),
                    cx,
                )
                .primary()
                .into_any_element(),
            );
        } else if self.modal == "delete" {
            content.push(
                div()
                    .text_sm()
                    .child(format!(
                        "删除“{}”？需要保留时，请先导出 JSON。",
                        text(&self.data["profile"], "name")
                    ))
                    .into_any_element(),
            );
            buttons.push(
                self.cmd_button(
                    "cancel-delete",
                    "取消",
                    json!({"action":"ui","kind":"close"}),
                    cx,
                )
                .into_any_element(),
            );
            buttons.push(
                self.cmd_button(
                    "confirm-delete",
                    "删除配置",
                    json!({"action":"deleteProfile"}),
                    cx,
                )
                .danger()
                .into_any_element(),
            );
        } else if self.modal.starts_with("preset") || self.modal == "graphic-confirm" {
            let (items, actions) = self.preset_modal(window, cx);
            content.extend(items);
            buttons.extend(actions);
        } else {
            for (heading, body) in [
                (
                    "信号路径",
                    "系统立体声 → 单声道混合 → 左声道 / 右声道 / 内置扬声器",
                ),
                (
                    "确认设备",
                    "设备与测量中选择输出设备，并勾选对应的物理通道。软件可独立控制的路数由设备提供的通道决定。",
                ),
                (
                    "逐路调音",
                    "通过独听检查每一路，再设置高低通、EQ、音量、极性和延迟。左右均为通用声道。",
                ),
                (
                    "编辑与对比",
                    "输入数值后按回车或离开输入框应用。↑↓ 微调，Shift 加快、Option 精调。存快照后再改参数，可切换对比。⌘Z 撤销，⇧⌘Z 重做。",
                ),
                (
                    "开始播放",
                    "独立模式请先退出 FineTune；联动模式在菜单栏勾选“FineTune 输入”，再启动处理。首次使用按提示授予音频录制权限，从较低总音量开始。",
                ),
            ] {
                content.push(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(
                            div()
                                .text_sm()
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(heading),
                        )
                        .child(label(body, cx))
                        .into_any_element(),
                );
            }
            content.push(
                div()
                    .flex()
                    .gap_2()
                    .children(
                        [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]
                            .iter()
                            .map(|(value, title)| {
                                self.cmd_button(
                                    format!("theme{value}"),
                                    *title,
                                    json!({"action":"ui","kind":"appearance","value":value}),
                                    cx,
                                )
                                .selected(self.appearance == *value)
                            }),
                    )
                    .into_any_element(),
            );
            buttons.push(
                self.cmd_button(
                    "close-guide",
                    "开始调音",
                    json!({"action":"ui","kind":"close"}),
                    cx,
                )
                .primary()
                .into_any_element(),
            );
        }
        Some(
            div()
                .absolute()
                .inset_0()
                .occlude()
                .bg(rgba(0x00000055))
                .flex()
                .items_center()
                .justify_center()
                .child(
                    panel(cx)
                        .w(px(600.))
                        .max_h(relative(0.88))
                        .shadow_xl()
                        .child(
                            div()
                                .text_xl()
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(title),
                        )
                        .child(
                            div()
                                .id("modal-content")
                                .overflow_y_scroll()
                                .flex()
                                .flex_col()
                                .gap_4()
                                .children(content),
                        )
                        .when(!self.error.is_empty(), |el| {
                            el.child(
                                div()
                                    .text_xs()
                                    .text_color(rgb(0xb76b22))
                                    .child(self.error.clone()),
                            )
                        })
                        .child(div().flex().justify_end().gap_2().pt_2().children(buttons)),
                )
                .into_any_element(),
        )
    }
}

impl Render for MonoSplit {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let header = self.header(window, cx);
        let sidebar = self.sidebar(cx);
        let graph = self.graph(window, cx);
        let controls = self.controls(window, cx);
        let editor = match self.page {
            1 => self.routing(window, cx).into_any_element(),
            2 => self.profiles(cx).into_any_element(),
            3 => self.preset_manager(window, cx).into_any_element(),
            _ => self.tuning(window, cx).into_any_element(),
        };
        let footer = self.footer(window, cx);
        let overlay = self.overlay(window, cx);
        let message = if !self.error.is_empty() {
            self.error.clone()
        } else if let Some(issue) = values(&self.data, "issues").first() {
            issue.as_str().unwrap_or("").to_owned()
        } else {
            text(&self.data, "message")
        };
        div()
            .id(SharedString::from(format!("workspace/{}/{}/{}",self.role,self.page,text(&self.data["profile"],"id"))))
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .text_sm()
            .font_family(".AppleSystemUIFont")
            .text_color(cx.theme().foreground)
            .bg(cx.theme().muted.opacity(0.35))
            .child(header)
            .child(
                div().flex().flex_1().min_h_0().child(sidebar).child(
                    div()
                        .flex()
                        .flex_col()
                        .flex_1()
                        .min_w_0()
                        .min_h_0()
                        .p_4()
                        .gap_3()
                        .child(graph)
                        .child(controls)
                        .child(editor),
                ),
            )
            .when(!message.is_empty(), |el| {
                el.child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .px_5()
                        .py_2()
                        .bg(Hsla::from(rgb(0xbc7b27)).opacity(0.10))
                        .text_color(if cx.theme().mode.is_dark() {
                            rgb(0xedbe7c)
                        } else {
                            rgb(0x93601f)
                        })
                        .child(div().text_xs().child(message))
                        .child(
                            self.cmd_button(
                                "dismiss-message",
                                "关闭提示",
                                json!({"action":"dismissMessage"}),
                                cx,
                            )
                            .ghost(),
                        ),
                )
            })
            .child(footer)
            .children(overlay)
    }
}

#[derive(Clone, Copy)]
struct PlotGeometry {
    left: Pixels,
    right: Pixels,
    top: Pixels,
    bottom: Pixels,
    upper: f64,
    low: f64,
    high: f64,
}
impl PlotGeometry {
    fn new(b: Bounds<Pixels>, upper: f64, phase: bool) -> Self {
        Self {
            left: b.left() + px(38.),
            right: b.right() - px(35.),
            top: b.top() + px(12.),
            bottom: b.bottom() - px(28.),
            upper,
            low: if phase { -180. } else { -60. },
            high: if phase { 180. } else { 24. },
        }
    }
    fn x(&self, f: f64) -> Pixels {
        self.left
            + px(((f / 20.).ln() / (self.upper / 20.).ln()) as f32
                * f32::from(self.right - self.left))
    }
    fn y(&self, v: f64) -> Pixels {
        self.bottom
            - px(((v - self.low) / (self.high - self.low)) as f32
                * f32::from(self.bottom - self.top))
    }
    fn frequency(&self, x: Pixels) -> f64 {
        20. * (self.upper / 20.).powf(
            (f32::from(x - self.left) / f32::from(self.right - self.left).max(1.)).clamp(0., 1.)
                as f64,
        )
    }
    fn value(&self, y: Pixels) -> f64 {
        self.low
            + (f32::from(self.bottom - y) / f32::from(self.bottom - self.top).max(1.)).clamp(0., 1.)
                as f64
                * (self.high - self.low)
    }
}
fn stroke(points: &[Point<Pixels>], color: Hsla, width: f32, window: &mut Window) {
    if points.len() < 2 {
        return;
    }
    let mut p = PathBuilder::stroke(px(width));
    p.move_to(points[0]);
    for point in &points[1..] {
        p.line_to(*point);
    }
    if let Ok(path) = p.build() {
        window.paint_path(path, color);
    }
}
fn stroke_dashed(points: &[Point<Pixels>], color: Hsla, window: &mut Window) {
    if points.len() < 2 {
        return;
    }
    let mut p = PathBuilder::stroke(px(1.)).dash_array(&[px(4.), px(3.)]);
    p.move_to(points[0]);
    for point in &points[1..] {
        p.line_to(*point);
    }
    if let Ok(path) = p.build() {
        window.paint_path(path, color);
    }
}
fn paint_text(text: &str, origin: Point<Pixels>, color: Hsla, window: &mut Window, cx: &mut App) {
    let run = TextRun {
        len: text.len(),
        font: font("Menlo"),
        color,
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let line = window
        .text_system()
        .shape_line(text.to_owned().into(), px(10.), &[run], None);
    let _ = line.paint(origin, px(13.), window, cx);
}
