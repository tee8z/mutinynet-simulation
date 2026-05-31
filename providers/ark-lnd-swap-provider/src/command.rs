use std::time::Duration;

use anyhow::{anyhow, Context};
use serde_json::{json, Value};
use tokio::{process::Command, time::timeout};

use crate::models::CommandResult;

pub async fn run_command(
    bin: &str,
    args: Vec<String>,
    envs: &[(String, String)],
    command_timeout: Duration,
) -> anyhow::Result<CommandResult> {
    let mut command = Command::new(bin);
    command.args(&args);
    for (key, value) in envs {
        command.env(key, value);
    }

    let output = timeout(command_timeout, command.output())
        .await
        .map_err(|_| anyhow!("command timed out: {bin} {}", args.join(" ")))?
        .with_context(|| format!("running command: {bin} {}", args.join(" ")))?;

    let stdout_text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = parse_output(&stdout_text);

    if !output.status.success() {
        return Err(anyhow!(
            "command failed: {bin} {}\nstatus: {}\nstdout: {}\nstderr: {}",
            args.join(" "),
            output.status,
            stdout_text,
            stderr
        ));
    }

    Ok(CommandResult { stdout, stderr })
}

fn parse_output(text: &str) -> Value {
    if text.is_empty() {
        Value::Null
    } else {
        serde_json::from_str(text).unwrap_or_else(|_| json!({ "raw": text }))
    }
}
