use actix_web::{post, App, HttpServer, HttpResponse, Responder};
use std::string::String;
use reqwest::Client;
use embryo::{Embryo, EmbryoList};
use serde_json::from_str;
use std::collections::HashMap;
use std::time::{Instant, Duration};
use std::fs::File;
use std::io::BufReader;
use rss::Channel;

#[post("/query")]
async fn query_handler(body: String) -> impl Responder {
    let embryo_list = generate_embryo_list(body).await;
    let response = EmbryoList { embryo_list };
    HttpResponse::Ok().json(response)
}

fn read_rss_config() -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let file = File::open("rss_config.json")?;
    let reader = BufReader::new(file);
    let config: HashMap<String, Vec<String>> = serde_json::from_reader(reader)?;

    if let Some(rss_feeds) = config.get("rss_feeds") {
        Ok(rss_feeds.clone())
    } else {
        Ok(Vec::new())
    }
}

async fn generate_embryo_list(json_string: String) -> Vec<Embryo> {
    let search: HashMap<String,String> = from_str(&json_string).expect("Can't parse JSON");
    let search_value = match search.get("value") {
        Some(v) => v,
        None => "",
    }.to_lowercase();
    let timeout : u64 = match search.get("timeout") {
        Some(t) => t.parse().expect("Can't parse as u64"),
        None => 10,
    };

    let rss_feeds = match read_rss_config() {
        Ok(rss_feeds) => rss_feeds,
        Err(err) => {
            eprintln!("Error reading RSS config: {:?}", err);
            Vec::new()
        }
    };

    let mut embryo_list = Vec::new();
    let start_time = Instant::now();
    let timeout_duration = Duration::from_secs(timeout);

    for feed_url in rss_feeds {
        let response = Client::new().get(feed_url).send().await;

        match response {
            Ok(response) => {
                if let Ok(body) = response.text().await {
                    let channel = Channel::read_from(body.as_bytes()).unwrap();
                    for item in channel.into_items() {
                        if start_time.elapsed() >= timeout_duration {
                            return embryo_list;
                        }
                        
                        let title = item.title().unwrap_or_default();
                        let link = item.link().unwrap_or_default();
                        let description = item.description().unwrap_or_default();

                        if title.to_lowercase().contains(&search_value) || link.to_lowercase().contains(&search_value) || description.to_lowercase().contains(&search_value) {
                            let embryo = Embryo {
                                properties: HashMap::from([ ("url".to_string(), link.to_string()), ("resume".to_string(),description.to_string())])
                            };
                            embryo_list.push(embryo);
                        }
                    }
                }
            }
            Err(e) => eprintln!("Error fetching RSS feed: {:?}", e),
        }
    }

    embryo_list
}

pub async fn start() -> std::io::Result<()> {
    match em_filter::find_port().await {
        Some(port) => {
            let filter_url = format!("http://localhost:{}/query", port);
            println!("Filter registrer: {}", filter_url);
            em_filter::register_filter(&filter_url).await;
            HttpServer::new(|| App::new().service(query_handler))
                .bind(format!("127.0.0.1:{}", port))?.run().await?;
        },
        None => {
            println!("Can't start");
        },
    }
    Ok(())
}

