use serde::{Deserialize, Serialize};

pub mod no_std_compat;

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Config {
    pub name: String,
    pub greeting: String,
}

pub fn hello(name: &str) -> String {
    format!("Hello, {name}!")
}

pub fn parse_config(json: &str) -> Result<Config, serde_json::Error> {
    serde_json::from_str(json)
}

pub fn render_config(config: &Config) -> Result<String, serde_json::Error> {
    serde_json::to_string(config)
}

pub async fn hello_async(name: &str) -> String {
    hello(name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::io::Write;

    #[test]
    fn hello_world() {
        assert_eq!(hello("world"), "Hello, world!");
    }

    #[test]
    fn hello_name() {
        assert_eq!(hello("flazel"), "Hello, flazel!");
    }

    #[test]
    fn config_roundtrip() {
        let config = Config {
            name: "flazel".to_string(),
            greeting: "Hello".to_string(),
        };
        let json = render_config(&config).unwrap();
        let parsed = parse_config(&json).unwrap();
        assert_eq!(config, parsed);
    }

    #[test]
    fn parse_invalid_json() {
        assert!(parse_config("not json").is_err());
    }

    #[tokio::test]
    async fn async_hello() {
        assert_eq!(hello_async("async").await, "Hello, async!");
    }

    proptest! {
        #[test]
        fn hello_contains_name(name in "[a-zA-Z0-9_-]{1,50}") {
            let result = hello(&name);
            prop_assert!(result.contains(&name));
            prop_assert!(result.starts_with("Hello, "));
            prop_assert!(result.ends_with('!'));
        }

        #[test]
        fn config_roundtrip_prop(
            name in "[a-zA-Z0-9_-]{1,50}",
            greeting in "[a-zA-Z ]{1,100}"
        ) {
            let config = Config { name, greeting };
            let json = render_config(&config).unwrap();
            let parsed = parse_config(&json).unwrap();
            prop_assert_eq!(config, parsed);
        }
    }

    #[test]
    fn tempfile_integration() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        let config = Config {
            name: "test".to_string(),
            greeting: "Hi".to_string(),
        };
        let json = render_config(&config).unwrap();
        write!(file, "{json}").unwrap();

        let contents = std::fs::read_to_string(file.path()).unwrap();
        let parsed = parse_config(&contents).unwrap();
        assert_eq!(config, parsed);
    }
}
