from addict import Dict
import os
# I am gradually modifying the tokens to the pseudo account in this project
all_token_key_session = Dict(
    woocommerce_api_key = os.environ.get("KLAVIS_WOOCOMMERCE_CONSUMER_KEY", "ck_woocommerce_token_emma_206rnIn"),
    woocommerce_api_secret = os.environ.get("KLAVIS_WOOCOMMERCE_CONSUMER_SECRET", "cs_woocommerce_token_emma_206rnIn"),
    woocommerce_site_url = os.environ.get("KLAVIS_WOOCOMMERCE_SITE_URL", "http://localhost:10003/store81"),
    woocommerce_config_file = os.path.join(os.path.dirname(__file__), "woocommerce_config.json"),
)