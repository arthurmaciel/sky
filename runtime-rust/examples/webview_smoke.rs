//! Smoke test for the real wry/tao Sky.Webview backend.
//! `cargo run --example webview_smoke --features webview` — opens a native window
//! rendering a counter; click events round-trip through the IPC bridge → update →
//! re-render. Run on a machine with a display + webkit2gtk.

use sky_runtime_rust::sky_runtime::html::{Attribute, Event, Html};
use sky_runtime_rust::sky_runtime::tea::{SkyCmd, SkySub};
use sky_runtime_rust::sky_runtime::webview::{webview_app, WebviewWindowCfg};

fn view(n: i64) -> Html<i64> {
    Html::HElement(
        "div".into(),
        vec![],
        vec![
            Html::HElement(
                "h1".into(),
                vec![],
                vec![Html::HText(format!("count: {n}"))],
            ),
            // A button that dispatches Msg = n+1 on click.
            Html::HElement(
                "button".into(),
                vec![Attribute::EventAttr(Event::OnMsg("click".into(), n + 1))],
                vec![Html::HText("increment".into())],
            ),
        ],
    )
}

fn main() {
    let task = webview_app::<i64, i64, String, _, _, _, _>(
        |()| (0i64, SkyCmd::None),
        |msg, _model| (msg, SkyCmd::None),
        view,
        |_m| SkySub::None,
        WebviewWindowCfg {
            title: "Sky Webview smoke".into(),
            size: (420, 280),
        },
    );
    let _ = sky_runtime_rust::sky_runtime::task::block_on(task);
}
