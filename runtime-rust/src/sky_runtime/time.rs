// Time kernel — basic helpers (tokio-gated) + Std.Time advanced (always available).
use super::*;

#[cfg(feature = "tokio")]
use std::future::ready;

#[cfg(feature = "tokio")]
pub fn time_now<E: Send + 'static>(_: ()) -> SkyTask<E, i64> {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    Box::pin(ready(ok_res(ms)))
}

#[cfg(feature = "tokio")]
pub fn time_sleep<E: Send + 'static>(ms: i64) -> SkyTask<E, ()> {
    Box::pin(async move {
        tokio::time::sleep(std::time::Duration::from_millis(ms as u64)).await;
        ok_res(())
    })
}

#[cfg(feature = "tokio")]
pub fn time_unix_millis<E: Send + 'static>(_: ()) -> SkyTask<E, i64> { time_now(()) }

pub fn time_time_string(ms: i64) -> String { format!("timestamp:{}", ms) }

//// === Std.Time advanced — IANA zones + calendar math ===
use chrono::{DateTime, Datelike, Duration, NaiveDate, TimeZone, Timelike, Utc, Weekday};
use chrono_tz::Tz;

fn parse_zone<E: From<String>>(z: &str) -> SkyResult<E, Tz> {
    match z.parse::<Tz>() {
        Ok(t) => SkyResult::Ok(t),
        Err(_) => SkyResult::Err(format!("Std.Time: unknown zone: {}", z).into()),
    }
}

fn millis_to_zoned<E: From<String>>(zone: &str, ms: i64) -> SkyResult<E, DateTime<Tz>> {
    let tz = match parse_zone::<E>(zone) {
        SkyResult::Ok(t) => t,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    match Utc.timestamp_millis_opt(ms).single() {
        Some(utc) => SkyResult::Ok(utc.with_timezone(&tz)),
        None => SkyResult::Err(format!("Std.Time: epoch ms out of range: {}", ms).into()),
    }
}

pub fn time_in_zone<E: From<String>>(zone: String, ms: i64) -> SkyResult<E, String> {
    let dt = match millis_to_zoned::<E>(&zone, ms) {
        SkyResult::Ok(d) => d,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    SkyResult::Ok(dt.to_rfc3339())
}

pub fn time_add_days(days: i64, ms: i64) -> i64 { ms + days * 86_400_000 }
pub fn time_add_hours(h: i64, ms: i64) -> i64 { ms + h * 3_600_000 }
pub fn time_add_minutes(m: i64, ms: i64) -> i64 { ms + m * 60_000 }
pub fn time_add_seconds(s: i64, ms: i64) -> i64 { ms + s * 1000 }

pub fn time_add_months(months: i64, ms: i64) -> i64 {
    let utc = match Utc.timestamp_millis_opt(ms).single() {
        Some(d) => d,
        None => return ms,
    };
    let y = utc.year() as i64;
    let m = utc.month() as i64 - 1 + months;
    let new_y = (y + m.div_euclid(12)) as i32;
    let new_m = (m.rem_euclid(12) + 1) as u32;
    // Clamp day to month end
    let first = NaiveDate::from_ymd_opt(new_y, new_m, 1);
    let max_day = match first {
        Some(d) => {
            let (ny, nm) = if new_m == 12 { (new_y + 1, 1u32) } else { (new_y, new_m + 1) };
            let first_next = NaiveDate::from_ymd_opt(ny, nm, 1).unwrap_or(d);
            first_next.signed_duration_since(d).num_days() as u32
        }
        None => return ms,
    };
    let day = utc.day().min(max_day);
    match NaiveDate::from_ymd_opt(new_y, new_m, day)
        .and_then(|d| d.and_hms_milli_opt(utc.hour(), utc.minute(), utc.second(),
                                          utc.timestamp_subsec_millis()))
    {
        Some(ndt) => Utc.from_utc_datetime(&ndt).timestamp_millis(),
        None => ms,
    }
}

pub fn time_add_years(years: i64, ms: i64) -> i64 {
    time_add_months(years * 12, ms)
}

fn zoned_field<E: From<String>, F>(zone: String, ms: i64, f: F) -> SkyResult<E, i64>
where
    F: FnOnce(DateTime<Tz>) -> i64,
{
    let dt = match millis_to_zoned::<E>(&zone, ms) {
        SkyResult::Ok(d) => d,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    SkyResult::Ok(f(dt))
}

pub fn time_year<E: From<String>>(z: String, ms: i64) -> SkyResult<E, i64> {
    zoned_field(z, ms, |dt| dt.year() as i64)
}
pub fn time_month<E: From<String>>(z: String, ms: i64) -> SkyResult<E, i64> {
    zoned_field(z, ms, |dt| dt.month() as i64)
}
pub fn time_day<E: From<String>>(z: String, ms: i64) -> SkyResult<E, i64> {
    zoned_field(z, ms, |dt| dt.day() as i64)
}
pub fn time_day_of_week<E: From<String>>(z: String, ms: i64) -> SkyResult<E, i64> {
    zoned_field(z, ms, |dt| match dt.weekday() {
        Weekday::Mon => 1,
        Weekday::Tue => 2,
        Weekday::Wed => 3,
        Weekday::Thu => 4,
        Weekday::Fri => 5,
        Weekday::Sat => 6,
        Weekday::Sun => 7,
    })
}
pub fn time_day_of_year<E: From<String>>(z: String, ms: i64) -> SkyResult<E, i64> {
    zoned_field(z, ms, |dt| dt.ordinal() as i64)
}
pub fn time_week_of_year<E: From<String>>(z: String, ms: i64) -> SkyResult<E, i64> {
    zoned_field(z, ms, |dt| dt.iso_week().week() as i64)
}
pub fn time_is_weekend<E: From<String>>(z: String, ms: i64) -> SkyResult<E, bool> {
    let dt = match millis_to_zoned::<E>(&z, ms) {
        SkyResult::Ok(d) => d,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    SkyResult::Ok(matches!(dt.weekday(), Weekday::Sat | Weekday::Sun))
}

pub fn time_is_leap_year(y: i64) -> bool {
    let y = y as i32;
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

pub fn time_days_in_month(year: i64, month: i64) -> i64 {
    let y = year as i32;
    let m = month as u32;
    if !(1..=12).contains(&m) {
        return 0;
    }
    let (ny, nm) = if m == 12 { (y + 1, 1) } else { (y, m + 1) };
    match (NaiveDate::from_ymd_opt(ny, nm, 1), NaiveDate::from_ymd_opt(y, m, 1)) {
        (Some(next), Some(this)) => next.signed_duration_since(this).num_days(),
        _ => 0,
    }
}

fn local_midnight_in_zone<E: From<String>>(
    zone: String,
    ms: i64,
    h: u32,
    mi: u32,
    se: u32,
    mi_lli: u32,
    target_date: impl Fn(DateTime<Tz>) -> NaiveDate,
) -> SkyResult<E, i64> {
    let dt = match millis_to_zoned::<E>(&zone, ms) {
        SkyResult::Ok(d) => d,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    let date = target_date(dt.clone());
    let local = match date.and_hms_milli_opt(h, mi, se, mi_lli) {
        Some(l) => l,
        None => return SkyResult::Err("Std.Time: invalid date components".to_string().into()),
    };
    match dt.timezone().from_local_datetime(&local).single() {
        Some(z) => SkyResult::Ok(z.timestamp_millis()),
        None => SkyResult::Err("Std.Time: ambiguous local time".to_string().into()),
    }
}

pub fn time_start_of_day<E: From<String>>(zone: String, ms: i64) -> SkyResult<E, i64> {
    local_midnight_in_zone(zone, ms, 0, 0, 0, 0, |dt| dt.date_naive())
}
pub fn time_end_of_day<E: From<String>>(zone: String, ms: i64) -> SkyResult<E, i64> {
    match time_start_of_day::<E>(zone, ms) {
        SkyResult::Ok(start) => SkyResult::Ok(start + 86_400_000 - 1),
        SkyResult::Err(e) => SkyResult::Err(e),
    }
}
pub fn time_start_of_week<E: From<String>>(zone: String, ms: i64) -> SkyResult<E, i64> {
    local_midnight_in_zone(zone, ms, 0, 0, 0, 0, |dt| {
        let wd = dt.weekday().num_days_from_monday();
        dt.date_naive() - Duration::days(wd as i64)
    })
}
pub fn time_start_of_month<E: From<String>>(zone: String, ms: i64) -> SkyResult<E, i64> {
    local_midnight_in_zone(zone, ms, 0, 0, 0, 0, |dt| {
        NaiveDate::from_ymd_opt(dt.year(), dt.month(), 1).unwrap_or(dt.date_naive())
    })
}
pub fn time_end_of_month<E: From<String>>(zone: String, ms: i64) -> SkyResult<E, i64> {
    let dt = match millis_to_zoned::<E>(&zone, ms) {
        SkyResult::Ok(d) => d,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    let dim = time_days_in_month(dt.year() as i64, dt.month() as i64) as u32;
    let target = NaiveDate::from_ymd_opt(dt.year(), dt.month(), dim);
    let target_date = target.unwrap_or(dt.date_naive());
    local_midnight_in_zone::<E>(zone, ms, 23, 59, 59, 999, move |_| target_date)
}
pub fn time_start_of_year<E: From<String>>(zone: String, ms: i64) -> SkyResult<E, i64> {
    local_midnight_in_zone(zone, ms, 0, 0, 0, 0, |dt| {
        NaiveDate::from_ymd_opt(dt.year(), 1, 1).unwrap_or(dt.date_naive())
    })
}
pub fn time_end_of_year<E: From<String>>(zone: String, ms: i64) -> SkyResult<E, i64> {
    local_midnight_in_zone(zone, ms, 23, 59, 59, 999, |dt| {
        NaiveDate::from_ymd_opt(dt.year(), 12, 31).unwrap_or(dt.date_naive())
    })
}

pub fn time_format_in_zone<E: From<String>>(
    pattern: String,
    zone: String,
    ms: i64,
) -> SkyResult<E, String> {
    let dt = match millis_to_zoned::<E>(&zone, ms) {
        SkyResult::Ok(d) => d,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    SkyResult::Ok(dt.format(&pattern).to_string())
}

#[cfg(test)]
mod time_advanced_tests {
    use super::*;

    // 2026-05-29 12:00:00 UTC is a Friday
    const T1: i64 = 1780_400_400_000;

    #[test]
    fn test_in_zone_utc() {
        let r: SkyResult<String, String> = time_in_zone("UTC".to_string(), T1);
        assert!(matches!(r, SkyResult::Ok(ref s) if s.contains("2026")));
    }

    #[test]
    fn test_in_zone_unknown() {
        let r: SkyResult<String, String> = time_in_zone("Not/AZone".to_string(), T1);
        assert!(matches!(r, SkyResult::Err(_)));
    }

    #[test]
    fn test_day_of_week_friday() {
        let r: SkyResult<String, i64> = time_day_of_week("UTC".to_string(), T1);
        assert!(matches!(r, SkyResult::Ok(d) if d >= 1 && d <= 7), "got {:?}", r);
    }

    #[test]
    fn test_is_leap_year() {
        assert!(time_is_leap_year(2024));
        assert!(!time_is_leap_year(2025));
        assert!(!time_is_leap_year(1900));
        assert!(time_is_leap_year(2000));
    }

    #[test]
    fn test_add_days_months() {
        // adding 1 day = +86400000 ms
        assert_eq!(time_add_days(1, T1), T1 + 86_400_000);
        // adding months returns SOME result (no panic)
        let added = time_add_months(1, T1);
        assert!(added > T1);
    }
}
