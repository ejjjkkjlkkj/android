use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::time::Duration;

#[derive(Clone, Copy, Debug)]
pub struct QmpClient {
    port: u16,
}

impl QmpClient {
    pub fn new(port: u16) -> Self {
        Self { port }
    }

    pub fn execute(&self, command: &str, arguments: Option<Value>) -> Result<Value, String> {
        let address = format!("127.0.0.1:{}", self.port);
        let stream = TcpStream::connect(&address)
            .map_err(|error| format!("Cannot connect to QMP at {address}: {error}"))?;
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .map_err(|error| format!("Cannot set QMP read timeout: {error}"))?;
        stream
            .set_write_timeout(Some(Duration::from_secs(3)))
            .map_err(|error| format!("Cannot set QMP write timeout: {error}"))?;

        let mut writer = stream
            .try_clone()
            .map_err(|error| format!("Cannot clone QMP socket: {error}"))?;
        let mut reader = BufReader::new(stream);

        let greeting = read_json_line(&mut reader)?;
        if greeting.get("QMP").is_none() {
            return Err("QMP server did not send a valid greeting.".to_owned());
        }

        send_request(&mut writer, &json!({"execute": "qmp_capabilities"}))?;
        let capabilities = read_response(&mut reader)?;
        check_response("qmp_capabilities", &capabilities)?;

        let request = match arguments {
            Some(arguments) => json!({"execute": command, "arguments": arguments}),
            None => json!({"execute": command}),
        };
        send_request(&mut writer, &request)?;
        let response = read_response(&mut reader)?;
        check_response(command, &response)?;
        Ok(response)
    }

    pub fn query_status(&self) -> Result<String, String> {
        let response = self.execute("query-status", None)?;
        Ok(response
            .get("return")
            .and_then(|value| value.get("status"))
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned())
    }
}

fn send_request(writer: &mut TcpStream, request: &Value) -> Result<(), String> {
    writeln!(writer, "{request}").map_err(|error| format!("Cannot send QMP request: {error}"))?;
    writer
        .flush()
        .map_err(|error| format!("Cannot flush QMP request: {error}"))
}

fn read_json_line(reader: &mut BufReader<TcpStream>) -> Result<Value, String> {
    let mut line = String::new();
    let bytes = reader
        .read_line(&mut line)
        .map_err(|error| format!("QMP read failed: {error}"))?;
    if bytes == 0 {
        return Err("QMP connection closed before data was received.".to_owned());
    }
    serde_json::from_str(line.trim()).map_err(|error| format!("Invalid QMP JSON: {error}"))
}

fn read_response(reader: &mut BufReader<TcpStream>) -> Result<Value, String> {
    loop {
        let value = read_json_line(reader)?;
        if value.get("return").is_some() || value.get("error").is_some() {
            return Ok(value);
        }
        // QMP events can arrive between a request and its response. They are
        // intentionally ignored here; a persistent event stream will consume
        // them in a later runtime-manager milestone.
    }
}

fn check_response(command: &str, response: &Value) -> Result<(), String> {
    if let Some(error) = response.get("error") {
        return Err(format!("QMP command {command} failed: {error}"));
    }
    Ok(())
}
