from addict import Dict
import os

all_token_key_session = Dict(
    woocommerce_api_key = os.environ.get("KLAVIS_WOOCOMMERCE_CONSUMER_KEY", "ck_woocommerce_token_Vgarcia128jr"),
    woocommerce_api_secret = os.environ.get("KLAVIS_WOOCOMMERCE_CONSUMER_SECRET", "cs_woocommerce_token_Vgarcia128jr"),
    woocommerce_site_url = os.environ.get("KLAVIS_WOOCOMMERCE_SITE_URL", "http://localhost:10003/store82"),
    
    emails_config_file = os.path.join(os.path.dirname(__file__), "emails_config.json"),
)