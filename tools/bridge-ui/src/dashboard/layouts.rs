use maud::{html, Markup, DOCTYPE};

use super::asset_hashes;

pub fn base(title: &str, content: Markup) -> Markup {
    html! {
        (DOCTYPE)
        html lang="en" {
            head {
                meta charset="UTF-8";
                meta name="viewport" content="width=device-width, initial-scale=1.0";
                title { "Mutinynet Bridge - " (title) }
                link rel="stylesheet" href=(format!("/static/{}", asset_hashes::CSS_HASHED));
            }
            body {
                header class="topbar" {
                    a class="brand" href="/" {
                        span class="brand-mark" { "M" }
                        span { "Mutinynet Bridge" }
                    }
                    nav class="topnav" aria-label="primary" {
                        a href="#cluster" { "Cluster" }
                        a href="#flows" { "Flows" }
                        a href="#timeline" { "Timeline" }
                    }
                }
                main class="shell" {
                    (content)
                }
                script src=(format!("/static/{}", asset_hashes::JS_HASHED)) {}
            }
        }
    }
}
