//! Std.Email — provider-abstract email send (Resend / SendGrid / SES / SMTP).
//!
//! Mirror of `runtime-go/rt/email_kernel.go`. The Sky records
//! (`EmailMessage` / `Attachment` / `SesConfig` / `SmtpConfig`) and the
//! `EmailProvider` ADT map to the runtime types below via the
//! runtimeOpaqueTypes registry — so the generated `StdEmail*` are `pub use`
//! aliases, Sky field access + record literals resolve onto these pub fields,
//! and `Resend "key"` / `Ses cfg` construct the enum variants directly.
//!
//! Field names match the Sky aliases verbatim (camelCase `textBody` /
//! `htmlBody` / `replyTo` / `mimeType` — hence the non_snake_case allow).
//!
//! Networking parity with Go: Resend + SendGrid + SES (v2, SigV4) over HTTPS.
//! SMTP is not yet ported (needs an SMTP transport crate) — it returns a clear
//! `Err` so the surface is complete and the gap is explicit.
//!
//! `SKY_EMAIL_DRY_RUN=1` short-circuits every provider and returns a synthetic
//! id — used by tests so they don't depend on third-party services.
//! `SKY_EMAIL_ENDPOINT_<PROVIDER>` overrides per-provider URLs for fixtures.

use super::*;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

/// Sky.Email.EmailMessage — field names/types match the Sky record alias.
#[allow(non_snake_case)]
#[derive(Clone, Debug)]
pub struct EmailMessage {
    pub from: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub textBody: String,
    pub htmlBody: String,
    pub attachments: Vec<EmailAttachment>,
    pub replyTo: String,
}

/// Sky.Email.Attachment — `content` carries raw bytes (Sky.Core.Bytes alias).
#[allow(non_snake_case)]
#[derive(Clone, Debug)]
pub struct EmailAttachment {
    pub filename: String,
    pub mimeType: String,
    pub content: String,
}

/// Sky.Email.SesConfig.
#[derive(Clone, Debug)]
pub struct SesConfig {
    pub region: String,
    pub key: String,
    pub secret: String,
}

/// Sky.Email.SmtpConfig.
#[derive(Clone, Debug)]
pub struct SmtpConfig {
    pub host: String,
    pub port: i64,
    pub user: String,
    pub pass: String,
}

/// Sky.Email.EmailProvider — the ADT; variant names match the Sky ctors.
#[derive(Clone, Debug)]
pub enum EmailProvider {
    Resend(String),
    Ses(SesConfig),
    SendGrid(String),
    Smtp(SmtpConfig),
}

fn email_gen_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    hex::encode(nanos.to_le_bytes())
}

fn email_endpoint(provider: &str, def: &str) -> String {
    let env = format!("SKY_EMAIL_ENDPOINT_{}", provider.to_uppercase());
    std::env::var(env).unwrap_or_else(|_| def.to_string())
}

/// Email.send : EmailProvider -> EmailMessage -> Task Error String
pub fn email_send<E: From<String> + Send + 'static>(
    provider: EmailProvider,
    msg: EmailMessage,
) -> SkyTask<E, String> {
    Box::pin(async move {
        if std::env::var("SKY_EMAIL_DRY_RUN").as_deref() == Ok("1") {
            return SkyResult::Ok(format!("dry-run-{}", email_gen_id()));
        }
        if msg.from.is_empty() {
            return SkyResult::Err("email.send: from required".to_string().into());
        }
        if msg.to.is_empty() {
            return SkyResult::Err(
                "email.send: at least one recipient required".to_string().into(),
            );
        }
        match provider {
            EmailProvider::Resend(key) => send_resend(&key, &msg).await,
            EmailProvider::SendGrid(key) => send_sendgrid(&key, &msg).await,
            EmailProvider::Ses(cfg) => send_ses(&cfg, &msg).await,
            EmailProvider::Smtp(cfg) => send_smtp(&cfg, &msg),
        }
    })
}

// ──────────────────── HTTP helper ────────────────────

async fn email_post_json<E: From<String>>(
    url: &str,
    headers: &[(&str, String)],
    payload: Vec<u8>,
) -> Result<serde_json::Value, E> {
    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
    {
        Ok(c) => c,
        Err(e) => return Err(format!("email: client build failed: {}", e).into()),
    };
    let mut rb = client.post(url).body(payload);
    for (k, v) in headers {
        rb = rb.header(*k, v.as_str());
    }
    let resp = match rb.send().await {
        Ok(r) => r,
        Err(e) => return Err(format!("email: request failed: {}", e).into()),
    };
    let status = resp.status().as_u16();
    let body = resp.text().await.unwrap_or_default();
    if status >= 400 {
        return Err(format!("email: status {}: {}", status, body).into());
    }
    Ok(serde_json::from_str(&body).unwrap_or(serde_json::Value::Null))
}

// ──────────────────── Resend ────────────────────

async fn send_resend<E: From<String>>(api_key: &str, m: &EmailMessage) -> SkyResult<E, String> {
    if api_key.is_empty() {
        return SkyResult::Err("email.send/Resend: empty API key".to_string().into());
    }
    let mut body = serde_json::Map::new();
    body.insert("from".into(), m.from.clone().into());
    body.insert("to".into(), to_json_array(&m.to));
    body.insert("subject".into(), m.subject.clone().into());
    if !m.cc.is_empty() {
        body.insert("cc".into(), to_json_array(&m.cc));
    }
    if !m.bcc.is_empty() {
        body.insert("bcc".into(), to_json_array(&m.bcc));
    }
    if !m.textBody.is_empty() {
        body.insert("text".into(), m.textBody.clone().into());
    }
    if !m.htmlBody.is_empty() {
        body.insert("html".into(), m.htmlBody.clone().into());
    }
    if !m.replyTo.is_empty() {
        body.insert("reply_to".into(), m.replyTo.clone().into());
    }
    if !m.attachments.is_empty() {
        let atts: Vec<serde_json::Value> = m
            .attachments
            .iter()
            .map(|a| {
                serde_json::json!({
                    "filename": a.filename,
                    "content": a.content.as_bytes(),
                })
            })
            .collect();
        body.insert("attachments".into(), atts.into());
    }
    let payload = serde_json::to_vec(&serde_json::Value::Object(body)).unwrap_or_default();
    let endpoint = email_endpoint("resend", "https://api.resend.com/emails");
    let resp: serde_json::Value = match email_post_json(
        &endpoint,
        &[
            ("Authorization", format!("Bearer {}", api_key)),
            ("Content-Type", "application/json".to_string()),
        ],
        payload,
    )
    .await
    {
        Ok(v) => v,
        Err(e) => return SkyResult::Err(e),
    };
    let id = resp
        .get("id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("resend-{}", email_gen_id()));
    SkyResult::Ok(id)
}

// ──────────────────── SendGrid ────────────────────

async fn send_sendgrid<E: From<String>>(api_key: &str, m: &EmailMessage) -> SkyResult<E, String> {
    if api_key.is_empty() {
        return SkyResult::Err("email.send/SendGrid: empty API key".to_string().into());
    }
    let mut personalisation = serde_json::Map::new();
    personalisation.insert("to".into(), addr_objs(&m.to));
    if !m.cc.is_empty() {
        personalisation.insert("cc".into(), addr_objs(&m.cc));
    }
    if !m.bcc.is_empty() {
        personalisation.insert("bcc".into(), addr_objs(&m.bcc));
    }
    let mut content: Vec<serde_json::Value> = Vec::new();
    if !m.textBody.is_empty() {
        content.push(serde_json::json!({ "type": "text/plain", "value": m.textBody }));
    }
    if !m.htmlBody.is_empty() {
        content.push(serde_json::json!({ "type": "text/html", "value": m.htmlBody }));
    }
    let mut body = serde_json::json!({
        "personalizations": [ serde_json::Value::Object(personalisation) ],
        "from": { "email": m.from },
        "subject": m.subject,
        "content": content,
    });
    if !m.replyTo.is_empty() {
        body["reply_to"] = serde_json::json!({ "email": m.replyTo });
    }
    let payload = serde_json::to_vec(&body).unwrap_or_default();
    let endpoint = email_endpoint("sendgrid", "https://api.sendgrid.com/v3/mail/send");
    match email_post_json::<E>(
        &endpoint,
        &[
            ("Authorization", format!("Bearer {}", api_key)),
            ("Content-Type", "application/json".to_string()),
        ],
        payload,
    )
    .await
    {
        Ok(_) => SkyResult::Ok(format!("sendgrid-{}", email_gen_id())),
        Err(e) => SkyResult::Err(e),
    }
}

// ──────────────────── SES v2 (SigV4) ────────────────────

async fn send_ses<E: From<String>>(cfg: &SesConfig, m: &EmailMessage) -> SkyResult<E, String> {
    if cfg.region.is_empty() || cfg.key.is_empty() || cfg.secret.is_empty() {
        return SkyResult::Err(
            "email.send/Ses: region+key+secret required".to_string().into(),
        );
    }
    let mut simple = serde_json::json!({
        "Subject": { "Data": m.subject, "Charset": "UTF-8" },
        "Body": { "Text": { "Data": m.textBody, "Charset": "UTF-8" } },
    });
    if !m.htmlBody.is_empty() {
        simple["Body"]["Html"] = serde_json::json!({ "Data": m.htmlBody, "Charset": "UTF-8" });
    }
    let mut destination = serde_json::json!({ "ToAddresses": m.to });
    if !m.cc.is_empty() {
        destination["CcAddresses"] = serde_json::json!(m.cc);
    }
    if !m.bcc.is_empty() {
        destination["BccAddresses"] = serde_json::json!(m.bcc);
    }
    let body = serde_json::json!({
        "FromEmailAddress": m.from,
        "Destination": destination,
        "Content": { "Simple": simple },
    });
    let payload = serde_json::to_vec(&body).unwrap_or_default();

    let host = format!("email.{}.amazonaws.com", cfg.region);
    let headers = ses_sign_v4(&host, &cfg.region, &cfg.key, &cfg.secret, &payload);
    let endpoint = email_endpoint(
        "ses",
        &format!("https://{}/v2/email/outbound-emails", host),
    );
    let header_refs: Vec<(&str, String)> =
        headers.iter().map(|(k, v)| (*k, v.clone())).collect();
    match email_post_json::<E>(&endpoint, &header_refs, payload).await {
        Ok(_) => SkyResult::Ok(format!("ses-{}", email_gen_id())),
        Err(e) => SkyResult::Err(e),
    }
}

fn hex_sha256(b: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(b);
    hex::encode(h.finalize())
}

fn hmac_bytes(key: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("hmac key");
    mac.update(msg);
    mac.finalize().into_bytes().to_vec()
}

fn ses_sign_v4(
    host: &str,
    region: &str,
    key: &str,
    secret: &str,
    payload: &[u8],
) -> Vec<(&'static str, String)> {
    // AWS SigV4 timestamps. Format YYYYMMDDTHHMMSSZ + YYYYMMDD.
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (amz_date, date_stamp) = sigv4_timestamps(secs);

    let canonical_request = [
        "POST",
        "/v2/email/outbound-emails",
        "",
        "content-type:application/json",
        &format!("host:{}", host),
        &format!("x-amz-date:{}", amz_date),
        "",
        "content-type;host;x-amz-date",
        &hex_sha256(payload),
    ]
    .join("\n");

    let credential_scope = format!("{}/{}/ses/aws4_request", date_stamp, region);
    let string_to_sign = [
        "AWS4-HMAC-SHA256",
        &amz_date,
        &credential_scope,
        &hex_sha256(canonical_request.as_bytes()),
    ]
    .join("\n");

    let k_date = hmac_bytes(format!("AWS4{}", secret).as_bytes(), date_stamp.as_bytes());
    let k_region = hmac_bytes(&k_date, region.as_bytes());
    let k_service = hmac_bytes(&k_region, b"ses");
    let k_signing = hmac_bytes(&k_service, b"aws4_request");
    let signature = hex::encode(hmac_bytes(&k_signing, string_to_sign.as_bytes()));

    let auth = format!(
        "AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders=content-type;host;x-amz-date, Signature={}",
        key, credential_scope, signature
    );
    vec![
        ("Content-Type", "application/json".to_string()),
        ("Host", host.to_string()),
        ("X-Amz-Date", amz_date),
        ("Authorization", auth),
    ]
}

// Convert a Unix-epoch second count into (YYYYMMDDTHHMMSSZ, YYYYMMDD) in UTC
// without pulling chrono into this module's hot path (chrono IS available, but
// a self-contained civil-from-days keeps the SigV4 logic auditable).
fn sigv4_timestamps(epoch_secs: u64) -> (String, String) {
    let days = (epoch_secs / 86_400) as i64;
    let rem = epoch_secs % 86_400;
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (y, mo, d) = civil_from_days(days);
    (
        format!("{:04}{:02}{:02}T{:02}{:02}{:02}Z", y, mo, d, hh, mm, ss),
        format!("{:04}{:02}{:02}", y, mo, d),
    )
}

// Howard Hinnant's civil_from_days — days since 1970-01-01 -> (y, m, d).
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// ──────────────────── SMTP (not yet ported) ────────────────────

fn send_smtp<E: From<String>>(_cfg: &SmtpConfig, _m: &EmailMessage) -> SkyResult<E, String> {
    SkyResult::Err(
        "email.send/Smtp: SMTP transport is not yet supported on the Rust backend \
         (use Resend / SendGrid / SES, or the Go backend for SMTP)"
            .to_string()
            .into(),
    )
}

// ──────────────────── small helpers ────────────────────

fn to_json_array(xs: &[String]) -> serde_json::Value {
    serde_json::Value::Array(xs.iter().map(|s| s.clone().into()).collect())
}

fn addr_objs(xs: &[String]) -> serde_json::Value {
    serde_json::Value::Array(
        xs.iter()
            .map(|s| serde_json::json!({ "email": s }))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn dry_run_returns_synthetic_id() {
        std::env::set_var("SKY_EMAIL_DRY_RUN", "1");
        let msg = EmailMessage {
            from: "a@example.com".into(),
            to: vec!["b@example.com".into()],
            cc: vec![],
            bcc: vec![],
            subject: "hi".into(),
            textBody: "hello".into(),
            htmlBody: String::new(),
            attachments: vec![],
            replyTo: String::new(),
        };
        let r: SkyResult<String, String> =
            email_send(EmailProvider::Resend("key".into()), msg).await;
        match r {
            SkyResult::Ok(id) => assert!(id.starts_with("dry-run-")),
            SkyResult::Err(e) => panic!("dry-run failed: {}", e),
        }
        std::env::remove_var("SKY_EMAIL_DRY_RUN");
    }

    #[test]
    fn civil_from_days_epoch() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        // 2021-01-01 is 18628 days after epoch.
        assert_eq!(civil_from_days(18628), (2021, 1, 1));
    }
}
