use super::*;

const FREQUENCIES: [f64; 10] = [
    32., 64., 125., 250., 500., 1000., 2000., 4000., 8000., 16000.,
];

impl MonoSplit {
    pub(super) fn equalizer(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let channel = self.channel();
        let state = self.data["presetStates"][ROLES[self.role]].clone();
        let title = if text(&state, "name").is_empty() {
            if values(&channel, "bands").is_empty() {
                "平直".into()
            } else {
                "自定义".into()
            }
        } else {
            format!(
                "{}{}",
                text(&state, "name"),
                if flag(&state, "modified") {
                    " · 已修改"
                } else {
                    ""
                }
            )
        };
        let mut presets = vec![(
            "平直 · 10 段".into(),
            json!({"action":"applyPreset","role":ROLES[self.role],"id":"flat"}),
        )];
        for p in values(&self.data, "eqPresets") {
            presets.push((
                text(&p, "name"),
                json!({"action":"applyPreset","role":ROLES[self.role],"id":p["id"]}),
            ));
        }
        let disabled = self.comparing();
        let editor = if self.graphic {
            self.graphic_eq(window, cx)
        } else {
            self.eq_table(window, cx).into_any_element()
        };
        panel(cx).flex_1().min_w_0().min_h_0().gap_2()
            .child(div().flex().items_center().gap_2()
                .child(self.cmd_button("eq-enabled",if flag(&channel,"eqEnabled"){"● 均衡器"}else{"○ 均衡器"},self.setting("channel","eqEnabled",json!(!flag(&channel,"eqEnabled")),None),cx).ghost().disabled(disabled))
                .child(div().flex_1())
                .child(self.cmd_button("graphic-view","图示",json!({"action":"ui","kind":"eqView","graphic":true}),cx).selected(self.graphic))
                .child(self.cmd_button("parametric-view","参数",json!({"action":"ui","kind":"eqView","graphic":false}),cx).selected(!self.graphic)))
            .child(div().flex().items_center().gap_2()
                .child(label("预设",cx)).child(self.menu_button("eq-presets",format!("{title}  ▾"),presets,cx)).child(div().flex_1())
                .when(flag(&state,"modified"),|el|el.child(self.cmd_button("update-preset","更新预设",json!({"action":"updatePreset","id":state["id"],"role":ROLES[self.role]}),cx).disabled(disabled)))
                .child(self.cmd_button("save-eq-preset","保存为…",json!({"action":"ui","kind":"presetModal","value":"preset-save","name":format!("{} EQ",NAMES[self.role])}),cx).disabled(disabled))
                .child(self.cmd_button("manage-eq-presets","管理",json!({"action":"ui","kind":"page","index":3}),cx)))
            .child(editor).into_any_element()
    }

    fn slider_editable(&self, index: usize) -> bool {
        let bands = values(&self.channel(), "bands");
        if let Some(band) = bands.get(index) {
            number(band, "frequency") < number(&self.data, "sampleRate") / 2.
                && ["peak", "lowShelf", "highShelf"].contains(&text(band, "kind").as_str())
        } else {
            bands.is_empty() && FREQUENCIES[index.min(9)] < number(&self.data, "sampleRate") / 2.
        }
    }
    fn set_graphic_gain(
        &mut self,
        index: usize,
        value: f64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.comparing() {
            return;
        }
        self.dispatch(json!({"action":"graphicGain","role":ROLES[self.role],"index":index,"value":(value.clamp(-30.,30.)*10.).round()/10.}),window,cx);
    }
    fn finish_slider(&mut self) {
        if self.sliding.take().is_some() {
            native::send(&json!({"action":"endGesture"}));
        }
    }
    fn graphic_eq(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let channel = self.channel();
        let bands = values(&channel, "bands");
        let count = if bands.is_empty() { 10 } else { bands.len() };
        self.selected_slider = self.selected_slider.min(count - 1);
        let frequencies: Vec<f64> = (0..count)
            .map(|i| {
                bands
                    .get(i)
                    .map(|b| number(b, "frequency"))
                    .unwrap_or(FREQUENCIES[i.min(9)])
            })
            .collect();
        let gain_capable: Vec<bool> = (0..count)
            .map(|i| {
                bands
                    .get(i)
                    .is_none_or(|b| !["highPass", "lowPass"].contains(&text(b, "kind").as_str()))
            })
            .collect();
        let gains: Vec<f64> = (0..count)
            .map(|i| bands.get(i).map(|b| number(b, "gainDB")).unwrap_or(0.))
            .collect();
        let extent = if gains.iter().any(|v| v.abs() > 12.) {
            30.
        } else {
            12.
        };
        let enabled: Vec<bool> = (0..count)
            .map(|i| bands.get(i).map(|b| flag(b, "enabled")).unwrap_or(true))
            .collect();
        let rate = number(&self.data, "sampleRate");
        let ink = color(self.role, cx.theme().mode.is_dark());
        let text_color = cx.theme().muted_foreground;
        let fg = cx.theme().foreground;
        let bg = cx.theme().background;
        let border = cx.theme().border;
        let active = flag(&channel, "eqEnabled") && !self.comparing();
        let selected = self.selected_slider;
        let bounds_cache = self.slider_bounds.clone();
        let sliders = div()
            .id("graphic-eq-sliders")
            .track_focus(&self.eq_focus)
            .h_full()
            .min_h(px(155.))
            .min_w(px((count as f32 * 48.) + 24.))
            .w_full()
            .flex_shrink_0()
            .cursor_pointer()
            .child(
                canvas(
                    move |bounds, _, _| {
                        bounds_cache.set(bounds);
                    },
                    move |bounds, _, window, cx| {
                        let g = SliderGeometry::new(bounds, extent, count);
                        for value in [-extent, 0., extent] {
                            paint_text(
                                &format!("{value:+.0}"),
                                point(bounds.left(), g.y(value) - px(6.)),
                                text_color,
                                window,
                                cx,
                            );
                        }
                        for i in 0..count {
                            let x = g.x(i);
                            let unavailable = frequencies[i] >= rate / 2. || !gain_capable[i];
                            let opacity = if active && enabled[i] && !unavailable {
                                1.
                            } else {
                                0.35
                            };
                            let accent = ink.opacity(opacity);
                            if selected == i {
                                window.paint_quad(quad(
                                    Bounds::new(
                                        point(x - px(19.), g.top - px(7.)),
                                        size(px(38.), g.bottom - g.top + px(14.)),
                                    ),
                                    px(8.),
                                    ink.opacity(0.055),
                                    px(0.),
                                    bg,
                                    Default::default(),
                                ));
                            }
                            stroke(&[point(x, g.top), point(x, g.bottom)], border, 3., window);
                            for tick in 0..=8 {
                                let y = g.top + (g.bottom - g.top) * (tick as f32 / 8.);
                                stroke(
                                    &[point(x - px(9.), y), point(x - px(5.), y)],
                                    border,
                                    0.8,
                                    window,
                                );
                            }
                            let y = g.y(gains[i]);
                            stroke(&[point(x, g.y(0.)), point(x, y)], accent, 3., window);
                            window.paint_quad(quad(
                                Bounds::new(point(x - px(8.), y - px(7.)), size(px(16.), px(16.))),
                                px(8.),
                                border.opacity(0.35),
                                px(0.),
                                bg,
                                Default::default(),
                            ));
                            window.paint_quad(quad(
                                Bounds::new(point(x - px(8.), y - px(8.)), size(px(16.), px(16.))),
                                px(8.),
                                bg,
                                px(if selected == i { 1.5 } else { 1. }),
                                if selected == i { accent } else { border },
                                Default::default(),
                            ));
                            window.paint_quad(quad(
                                Bounds::new(point(x - px(2.5), y - px(2.5)), size(px(5.), px(5.))),
                                px(2.5),
                                if selected == i {
                                    accent
                                } else {
                                    fg.opacity(opacity)
                                },
                                px(0.),
                                bg,
                                Default::default(),
                            ));
                            let f = if frequencies[i] >= 1000. {
                                format!("{}k", format_num(frequencies[i] / 1000.))
                            } else {
                                format_num(frequencies[i])
                            };
                            paint_text(
                                &f,
                                point(x - px(f.len() as f32 * 3.), g.bottom + px(12.)),
                                if unavailable {
                                    rgb(0xb76b22).into()
                                } else {
                                    fg
                                },
                                window,
                                cx,
                            );
                            let gain = if gain_capable[i] {
                                format!("{:+.1}", gains[i])
                            } else {
                                "—".into()
                            };
                            paint_text(
                                &gain,
                                point(x - px(gain.len() as f32 * 3.), g.bottom + px(29.)),
                                accent,
                                window,
                                cx,
                            );
                        }
                    },
                )
                .size_full(),
            )
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    if this.comparing() {
                        return;
                    }
                    let geometry = SliderGeometry::new(this.slider_bounds.get(), extent, count);
                    let index = geometry.index(event.position.x);
                    this.eq_focus.focus(window);
                    this.selected_slider = index;
                    if !this.slider_editable(index) {
                        cx.notify();
                        return;
                    }
                    if event.position.y > geometry.bottom + px(8.) {
                        cx.notify();
                        return;
                    }
                    this.sliding = Some(index);
                    native::send(&json!({"action":"beginGesture"}));
                    this.set_graphic_gain(
                        index,
                        if event.click_count == 2 {
                            0.
                        } else {
                            geometry.value(event.position.y)
                        },
                        window,
                        cx,
                    );
                }),
            )
            .on_mouse_move(
                cx.listener(move |this, event: &MouseMoveEvent, window, cx| {
                    if let Some(index) = this.sliding {
                        if event.dragging() {
                            let g = SliderGeometry::new(this.slider_bounds.get(), extent, count);
                            this.set_graphic_gain(index, g.value(event.position.y), window, cx);
                        }
                    }
                }),
            )
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.finish_slider()),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.finish_slider()),
            )
            .on_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
                let key = event.keystroke.key.as_str();
                match key {
                    "left" => this.selected_slider = this.selected_slider.saturating_sub(1),
                    "right" => this.selected_slider = (this.selected_slider + 1).min(count - 1),
                    "up" | "down" | "home" => {
                        if !this.slider_editable(this.selected_slider) {
                            return;
                        }
                        let ch = this.channel();
                        let bands = values(&ch, "bands");
                        let gain = bands
                            .get(this.selected_slider)
                            .map(|b| number(b, "gainDB"))
                            .unwrap_or(0.);
                        let step = if event.keystroke.modifiers.shift {
                            1.
                        } else {
                            0.1
                        };
                        this.set_graphic_gain(
                            this.selected_slider,
                            if key == "home" {
                                0.
                            } else {
                                gain + if key == "up" { step } else { -step }
                            },
                            window,
                            cx,
                        );
                    }
                    _ => return,
                }
                cx.stop_propagation();
                cx.notify();
            }));
        let preamp = self.numeric(
            "preampDB",
            number(&channel, "preampDB"),
            (-60., 12.),
            "dB",
            100.,
            window,
            cx,
        );
        let mut detail = vec![];
        if let Some(band) = bands.get(self.selected_slider) {
            let id = text(band, "id");
            let input = self.input(
                format!("graphic-gain/{}/{id}", self.role),
                format_num(number(band, "gainDB")),
                self.setting("band", "gainDB", band["gainDB"].clone(), Some(&id)),
                Some((-30., 30.)),
                0.1,
                self.comparing()
                    || !["peak", "lowShelf", "highShelf"].contains(&text(band, "kind").as_str()),
                window,
                cx,
            );
            detail.push(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(label(
                        format!("{} Hz", format_num(number(band, "frequency"))),
                        cx,
                    ))
                    .child(div().w(px(72.)).child(input))
                    .child(label("dB", cx))
                    .into_any_element(),
            );
        }
        div()
            .flex()
            .flex_col()
            .gap_2()
            .flex_1()
            .min_h_0()
            .child(
                div()
                    .id("graphic-eq-horizontal")
                    .overflow_x_scroll()
                    .flex_1()
                    .min_h(px(155.))
                    .w_full()
                    .child(sliders),
            )
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .gap_2()
                    .children(detail)
                    .child(
                        self.cmd_button(
                            "graphic-bank",
                            "10 段…",
                            json!({"action":"ui","kind":"modal","value":"graphic-confirm"}),
                            cx,
                        )
                        .ghost()
                        .disabled(self.comparing()),
                    )
                    .child(
                        self.cmd_button(
                            "graphic-flat",
                            "全部归零",
                            json!({"action":"flatEQ","role":ROLES[self.role]}),
                            cx,
                        )
                        .ghost()
                        .disabled(self.comparing()),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(label("前级", cx))
                            .child(preamp),
                    ),
            )
            .child(label("Hz · 拖动调整，双击归零 · ←→ 选频段，↑↓ 微调", cx))
            .into_any_element()
    }

    pub(super) fn preset_manager(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let presets = values(&self.data, "eqPresets");
        let selected = self.data["presetStates"][ROLES[self.role]].clone();
        let search = self.input(
            "preset-search".into(),
            self.preset_query.clone(),
            json!({"action":"local","field":"presetQuery"}),
            None,
            1.,
            false,
            window,
            cx,
        );
        let mut rows = vec![];
        for preset in presets.iter().filter(|p| {
            text(p, "name")
                .to_lowercase()
                .contains(&self.preset_query.to_lowercase())
        }) {
            let id = text(preset, "id");
            let name = text(preset, "name");
            let settings = &preset["settings"];
            rows.push(div().flex().items_center().gap_3().p_3().rounded_md().border_1().border_color(if preset["id"]==selected["id"]{color(self.role,cx.theme().mode.is_dark())}else{cx.theme().border})
                .child(div().flex_1().min_w_0().child(div().font_weight(FontWeight::MEDIUM).child(name.clone())).child(label(format!("{} 段 · 前级 {:+.1} dB{}",values(settings,"bands").len(),number(settings,"preampDB"),if preset["id"]==selected["id"]&&flag(&selected,"modified"){ " · 当前已修改" }else{""}),cx)))
                .child(self.cmd_button(format!("apply-preset{id}"),format!("应用到{}",NAMES[self.role]),json!({"action":"applyPreset","role":ROLES[self.role],"id":id}),cx).disabled(self.comparing()))
                .child(self.cmd_button(format!("rename-preset{id}"),"重命名",json!({"action":"ui","kind":"presetModal","value":"preset-rename","id":id,"name":name}),cx))
                .child(self.menu_button(format!("preset-more{id}"),"更多 ▾",vec![("复制预设".into(),json!({"action":"duplicatePreset","id":id})),("导出 JSON…".into(),json!({"action":"exportPreset","id":id}))],cx))
                .child(self.cmd_button(format!("delete-preset{id}"),"删除",json!({"action":"ui","kind":"presetModal","value":"preset-delete","id":id,"name":name}),cx).ghost()).into_any_element());
        }
        panel(cx).flex_1().min_h_0()
            .child(div().flex().items_center().gap_3().child(div().font_weight(FontWeight::SEMIBOLD).child("EQ 预设库")).child(label(format!("{} 个预设 · 三路均可使用",presets.len()),cx)).child(div().flex_1())
                .child(self.cmd_button("leave-presets","返回调音",json!({"action":"ui","kind":"page","index":0}),cx)))
            .child(div().flex().items_center().gap_3().child(label("搜索名称",cx)).child(div().w(px(200.)).child(search)).child(div().flex_1())
                .child(self.cmd_button("preset-import","导入预设…",json!({"action":"importPreset"}),cx))
                .child(self.cmd_button("preset-save-current","保存当前 EQ…",json!({"action":"ui","kind":"presetModal","value":"preset-save","name":format!("{} EQ",NAMES[self.role])}),cx).primary().disabled(self.comparing())))
            .child(div().id("eq-preset-list").flex_1().min_h_0().overflow_y_scroll().flex().flex_col().gap_2().children(rows)
                .when(presets.is_empty(),|el|el.child(div().p_5().flex().flex_col().gap_2().child(div().child("把满意的声音保存下来")).child(label("调整 EQ 后点“保存当前 EQ”，即可在不同声道和音箱配置间复用。",cx)))))
            .child(label("EQ 预设保存滤波器、启用状态与前级。完整接线和分频方案请保存为音箱配置。",cx)).into_any_element()
    }

    pub(super) fn preset_modal(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> (Vec<AnyElement>, Vec<AnyElement>) {
        let mut content = vec![];
        let mut buttons = vec![
            self.cmd_button(
                "preset-cancel",
                "取消",
                json!({"action":"ui","kind":"close"}),
                cx,
            )
            .into_any_element(),
        ];
        match self.modal.as_str() {
            "preset-save" | "preset-rename" => {
                let input = self.input(
                    "modal-preset-name".into(),
                    self.draft.clone(),
                    json!({"action":"local","field":"rename"}),
                    None,
                    1.,
                    false,
                    window,
                    cx,
                );
                content.push(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(label("预设名称", cx))
                        .child(input)
                        .into_any_element(),
                );
                if self.modal == "preset-save" {
                    content.push(
                        label(
                            format!(
                                "保存{}的 {} 段 EQ 与前级，预设可应用到任意声道。",
                                NAMES[self.role],
                                values(&self.channel(), "bands").len()
                            ),
                            cx,
                        )
                        .into_any_element(),
                    );
                }
                buttons.push(self.cmd_button("preset-confirm-save","保存预设",json!({"action":"ui","kind":if self.modal=="preset-save"{"savePreset"}else{"renamePreset"}}),cx).primary().into_any_element());
            }
            "preset-delete" => {
                content.push(
                    div()
                        .child(format!(
                            "删除“{}”？已应用到声道的 EQ 参数会保留。",
                            self.draft
                        ))
                        .into_any_element(),
                );
                buttons.push(
                    self.cmd_button(
                        "preset-confirm-delete",
                        "删除预设",
                        json!({"action":"ui","kind":"deletePreset"}),
                        cx,
                    )
                    .danger()
                    .into_any_element(),
                );
            }
            _ => {
                content.push(div().child("这会用 32 Hz 至 16 kHz 的 10 段平直峰值滤波器替换当前 EQ。当前 EQ 如需保留，请先保存为预设。可用 ⌘Z 撤销。分频、音量和延迟保留。 ").into_any_element());
                buttons.push(
                    self.cmd_button(
                        "graphic-confirm",
                        "替换为 10 段",
                        json!({"action":"ui","kind":"buildGraphic"}),
                        cx,
                    )
                    .primary()
                    .into_any_element(),
                );
            }
        }
        (content, buttons)
    }
}

struct SliderGeometry {
    left: Pixels,
    width: Pixels,
    top: Pixels,
    bottom: Pixels,
    extent: f64,
    count: usize,
}
impl SliderGeometry {
    fn new(bounds: Bounds<Pixels>, extent: f64, count: usize) -> Self {
        Self {
            count,
            left: bounds.left() + px(24.),
            width: (bounds.size.width - px(24.)).max(px(10.)),
            top: bounds.top() + px(10.),
            bottom: bounds.bottom() - px(48.),
            extent,
        }
    }
    fn x(&self, index: usize) -> Pixels {
        self.left + self.width * ((index as f32 + 0.5) / self.count as f32)
    }
    fn y(&self, value: f64) -> Pixels {
        self.bottom - (self.bottom - self.top) * ((value / self.extent + 1.) / 2.) as f32
    }
    fn value(&self, y: Pixels) -> f64 {
        ((f32::from(self.bottom - y) / f32::from(self.bottom - self.top).max(1.)) as f64 * 2. - 1.)
            .clamp(-1., 1.)
            * self.extent
    }
    fn index(&self, x: Pixels) -> usize {
        ((f32::from(x - self.left) / f32::from(self.width) * self.count as f32).floor() as i32)
            .clamp(0, self.count as i32 - 1) as usize
    }
}
