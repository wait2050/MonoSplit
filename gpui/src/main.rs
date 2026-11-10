mod app;
mod native;
mod response;
use gpui::*;
use gpui_component::Root;
use serde_json::json;
use std::time::Duration;
actions!(monosplit, [Quit, Undo, Redo, Left, Right, Builtin]);
fn main() {
    Application::new()
        .with_assets(gpui_component_assets::Assets)
        .run(|cx| {
            gpui_component::init(cx);
            cx.bind_keys([
                KeyBinding::new("cmd-q", Quit, None),
                KeyBinding::new("cmd-z", Undo, None),
                KeyBinding::new("cmd-shift-z", Redo, None),
                KeyBinding::new("cmd-1", Left, None),
                KeyBinding::new("cmd-2", Right, None),
                KeyBinding::new("cmd-3", Builtin, None),
            ]);
            cx.on_action(|_: &Quit, _| native::send(&json!({"action":"quit"})));
            cx.on_action(|_: &Undo, _| native::send(&json!({"action":"undo"})));
            cx.on_action(|_: &Redo, _| native::send(&json!({"action":"redo"})));
            cx.set_menus(vec![
                Menu {
                    name: "MonoSplit".into(),
                    items: vec![MenuItem::action("退出 MonoSplit", Quit)],
                },
                Menu {
                    name: "编辑".into(),
                    items: vec![
                        MenuItem::action("撤销参数修改", Undo),
                        MenuItem::action("重做参数修改", Redo),
                    ],
                },
            ]);
            let bounds = Bounds::centered(None, size(px(1280.), px(860.)), cx);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    titlebar: Some(TitlebarOptions {
                        title: Some("MonoSplit · GPUI".into()),
                        appears_transparent: false,
                        traffic_light_position: None,
                    }),
                    window_min_size: Some(size(px(1120.), px(800.))),
                    ..Default::default()
                },
                |window, cx| {
                    window.on_window_should_close(cx, |_, _| {
                        native::send(&json!({"action":"hide"}));
                        false
                    });
                    let view = cx.new(|cx| app::MonoSplit::new(window, cx));
                    let left = view.clone();
                    cx.on_action(move |_: &Left, cx| {
                        left.update(cx, |this, cx| this.select_role(0, cx))
                    });
                    let right = view.clone();
                    cx.on_action(move |_: &Right, cx| {
                        right.update(cx, |this, cx| this.select_role(1, cx))
                    });
                    let builtin = view.clone();
                    cx.on_action(move |_: &Builtin, cx| {
                        builtin.update(cx, |this, cx| this.select_role(2, cx))
                    });
                    cx.new(|cx| Root::new(view, window, cx))
                },
            )
            .unwrap();
            cx.on_app_quit(|_| {
                native::send(&json!({"action":"quit"}));
                async {
                    for _ in 0..80 {
                        if native::snapshot()
                            .ok()
                            .is_some_and(|v| v["shutdownComplete"].as_bool() == Some(true))
                        {
                            break;
                        }
                        smol::Timer::after(Duration::from_millis(25)).await;
                    }
                }
            })
            .detach();
            cx.activate(true);
        });
}
