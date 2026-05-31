use axum::response::Html;
use maud::html;

use super::layouts;

pub async fn home() -> Html<String> {
    let content = html! {
        section class="hero" {
            div {
                p class="eyebrow" { "RGB assets <-> Ark assets" }
                h1 { "Run the bridge and watch each leg move." }
            }
            div class="hero-actions" {
                button class="button" type="button" data-start-flow="setup-assets" {
                    "Prepare assets"
                }
                button class="button primary" type="button" data-start-flow="rgb-asset-to-ark-asset" {
                    "RGB -> Ark"
                }
                button class="button primary" type="button" data-start-flow="ark-asset-to-rgb-asset" {
                    "Ark -> RGB"
                }
                button class="button" type="button" data-start-flow="all" {
                    "Run both"
                }
                button class="button primary" type="button" data-start-flow="trustless-all" {
                    "Trustless both"
                }
            }
        }

        section id="cluster" class="panel" {
            div class="panel-heading" {
                div {
                    h2 { "Cluster" }
                    p { "Provider, RGB nodes, LND nodes, and Ark wallets." }
                }
                button id="refresh-cluster" class="button compact" type="button" { "Refresh" }
            }
            div id="cluster-grid" class="status-grid" {
                div class="empty" { "Loading cluster state..." }
            }
        }

        section class="panel" {
            div class="panel-heading" {
                div {
                    h2 { "Preflight" }
                    p { "Asset defaults used when the form is blank." }
                }
                button id="refresh-preflight" class="button compact" type="button" { "Refresh" }
            }
            div id="preflight-grid" class="status-grid" {
                div class="empty" { "Loading preflight checks..." }
            }
        }

        section class="grid two" {
            div class="panel" {
                div class="panel-heading" {
                    div {
                        h2 { "Setup" }
                        p { "P2P tunnel and local proof inventory." }
                    }
                }
                div class="action-row" {
                    button class="button" type="button" data-p2p-action="start" { "Start P2P tunnel" }
                    button class="button" type="button" data-p2p-action="stop" { "Stop P2P tunnel" }
                    button class="button compact" type="button" id="refresh-p2p" { "Refresh" }
                }
                div id="p2p-status" class="status-grid" {
                    div class="empty" { "Loading P2P tunnel state..." }
                }
                div class="action-row" {
                    button class="button primary" type="button" data-start-flow="setup-assets" {
                        "Prepare proof assets"
                    }
                }
            }

            div class="panel" {
                div class="panel-heading" {
                    div {
                        h2 { "Trustless" }
                        p { "Contract-bound Ark VTXO modes." }
                    }
                }
                div class="action-row" {
                    button class="button primary" type="button" data-start-flow="trustless-rgb-asset-to-ark-asset" {
                        "Trustless RGB -> Ark"
                    }
                    button class="button primary" type="button" data-start-flow="trustless-ark-asset-to-rgb-asset" {
                        "Trustless Ark -> RGB"
                    }
                    button class="button" type="button" data-start-flow="trustless-all" {
                        "Trustless both"
                    }
                }
            }
        }

        section id="flows" class="grid two" {
            div class="panel" {
                div class="panel-heading" {
                div {
                    h2 { "Run" }
                    p { ".env defaults apply when fields are blank." }
                    }
                }
                form id="flow-form" class="run-form" {
                    label {
                        span { "RGB asset id" }
                        input name="rgb_asset_id" autocomplete="off" placeholder="from RGB_MM_ASSET_ID";
                    }
                    label {
                        span { "Ark asset id" }
                        input name="ark_asset_id" autocomplete="off" placeholder="from BRIDGE_TEST_ARK_ASSET_ID";
                    }
                    div class="form-row" {
                        label {
                            span { "RGB units" }
                            input name="rgb_asset_amount" type="number" min="1" placeholder="10";
                        }
                        label {
                            span { "Ark units" }
                            input name="ark_asset_amount" type="number" min="1" placeholder="100";
                        }
                    }
                    div class="form-row" {
                        label {
                            span { "RGB -> Ark sats" }
                            input name="ln_to_ark_sats" type="number" min="1" placeholder="6000";
                        }
                        label {
                            span { "Ark -> RGB sats" }
                            input name="ark_to_rgb_sats" type="number" min="1" placeholder="1000";
                        }
                    }
                }
                div class="action-row" {
                    button class="button" type="button" data-start-flow="setup-assets" {
                        "Prepare assets"
                    }
                    button class="button primary" type="button" data-start-flow="rgb-asset-to-ark-asset" {
                        "Start RGB -> Ark"
                    }
                    button class="button primary" type="button" data-start-flow="ark-asset-to-rgb-asset" {
                        "Start Ark -> RGB"
                    }
                    button class="button" type="button" data-start-flow="all" { "Start both" }
                    button class="button primary" type="button" data-start-flow="trustless-all" {
                        "Start trustless both"
                    }
                }
                div id="flash" class="flash" {}
            }

            div class="panel" {
                div class="panel-heading" {
                div {
                    h2 { "Runs" }
                    p { "Current server process." }
                    }
                    button id="refresh-runs" class="button compact" type="button" { "Refresh" }
                }
                div id="run-list" class="run-list" {
                    div class="empty" { "No runs yet." }
                }
            }
        }

        section id="timeline" class="panel" {
            div class="panel-heading" {
                div {
                    h2 { "Timeline" }
                    p id="selected-run-label" { "Start or select a run." }
                }
                div id="run-state" class="state-pill muted" { "idle" }
            }
            div id="timeline-list" class="timeline" {
                div class="empty" { "No timeline selected." }
            }
        }

        section class="grid two detail-grid" {
            div class="panel" {
                div class="panel-heading" {
                    div {
                        h2 { "Log tail" }
                        p { "Harness stdout and stderr." }
                    }
                }
                textarea id="log-tail" class="log-box" readonly="" spellcheck="false" {
                    "No run selected."
                }
            }
            div class="panel" {
                div class="panel-heading" {
                div {
                    h2 { "Run JSON" }
                    p { "Selected run payload with local paths scrubbed." }
                    }
                }
                textarea id="json-view" class="json-box" readonly="" spellcheck="false" {
                    "{}"
                }
            }
        }
    };

    Html(layouts::base("Dashboard", content).into_string())
}
