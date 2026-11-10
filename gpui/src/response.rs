use serde_json::Value;
use std::f64::consts::PI;

pub fn number(v: &Value, key: &str) -> f64 {
    v[key].as_f64().unwrap_or(0.0)
}
pub fn flag(v: &Value, key: &str) -> bool {
    v[key].as_bool().unwrap_or(false)
}
pub fn text(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_owned()
}
pub fn values(v: &Value, key: &str) -> Vec<Value> {
    v[key].as_array().cloned().unwrap_or_default()
}
pub fn response(channel: &Value, frequency: f64, rate: f64, master: f64) -> (f64, f64) {
    let omega = -2.0 * PI * frequency / rate;
    let (mut re, mut im) = (1.0, 0.0);
    for c in channel["coefficients"].as_array().into_iter().flatten() {
        let Some(coefficients) = c.as_array().filter(|a| a.len() == 5) else {
            continue;
        };
        let a: [f64; 5] = std::array::from_fn(|i| coefficients[i].as_f64().unwrap_or(0.));
        let nr = a[0] + a[1] * omega.cos() + a[2] * (2. * omega).cos();
        let ni = a[1] * omega.sin() + a[2] * (2. * omega).sin();
        let dr = 1. + a[3] * omega.cos() + a[4] * (2. * omega).cos();
        let di = a[3] * omega.sin() + a[4] * (2. * omega).sin();
        let denom = dr * dr + di * di;
        let rr = (nr * dr + ni * di) / denom;
        let ii = (ni * dr - nr * di) / denom;
        (re, im) = (re * rr - im * ii, re * ii + im * rr);
    }
    let db = 20. * re.hypot(im).max(1e-12).log10()
        + number(channel, "gainDB")
        + number(channel, "preampDB")
        + master;
    let frames = (number(channel, "delayMS") * rate / 1000.).round();
    let phase = im.atan2(re) - 2. * PI * frequency * frames / rate
        + if flag(channel, "inverted") { PI } else { 0. };
    (db, phase.sin().atan2(phase.cos()) * 180. / PI)
}
pub const ROLES: [&str; 3] = ["woofer", "fullRange", "builtin"];
pub const NAMES: [&str; 3] = ["左声道", "右声道", "内置扬声器"];
pub const SYMBOLS: [&str; 3] = ["L", "R", "M"];
pub const SHAPES: [(&str, &str); 5] = [
    ("butterworth12", "Butterworth · 12 dB/oct"),
    ("butterworth24", "Butterworth · 24 dB/oct"),
    ("butterworth48", "Butterworth · 48 dB/oct"),
    ("linkwitzRiley24", "Linkwitz–Riley · 24 dB/oct"),
    ("linkwitzRiley48", "Linkwitz–Riley · 48 dB/oct"),
];
pub const KINDS: [(&str, &str); 5] = [
    ("peak", "峰值"),
    ("lowShelf", "低架"),
    ("highShelf", "高架"),
    ("highPass", "高通 · 二阶"),
    ("lowPass", "低通 · 二阶"),
];
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn unity_gain_polarity_and_sample_rounded_delay() {
        let mut c =
            json!({"coefficients":[],"gainDB":-6.,"preampDB":-3.,"delayMS":0.,"inverted":false});
        assert!((response(&c, 1000., 48000., -2.).0 + 11.).abs() < 1e-9);
        c["inverted"] = json!(true);
        assert!((response(&c, 1000., 48000., 0.).1.abs() - 180.).abs() < 1e-9);
        c["inverted"] = json!(false);
        c["delayMS"] = json!(0.01);
        assert!(response(&c, 1000., 44100., 0.).1.abs() < 1e-9);
        c["delayMS"] = json!(1.);
        assert!((response(&c, 100., 48000., 0.).1 + 36.).abs() < 1e-9);
    }
    #[test]
    fn actual_transferred_biquad_center_gain() {
        let a = 10f64.powf(6. / 40.);
        let w = 2. * PI * 1000. / 48000.;
        let alpha = w.sin() / 2.;
        let a0 = 1. + alpha / a;
        let c = json!({"coefficients":[[(1.+alpha*a)/a0,-2.*w.cos()/a0,(1.-alpha*a)/a0,-2.*w.cos()/a0,(1.-alpha/a)/a0]],"gainDB":0.,"preampDB":0.,"delayMS":0.});
        assert!((response(&c, 1000., 48000., 0.).0 - 6.).abs() < 1e-9);
    }
}
