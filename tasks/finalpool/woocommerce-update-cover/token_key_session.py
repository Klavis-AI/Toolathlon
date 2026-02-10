from addict import Dict
import os

all_token_key_session = Dict(

    woocommerce_api_key = os.environ.get("KLAVIS_WOOCOMMERCE_CONSUMER_KEY", "ck_woocommerce_token_Ttorres9177j"),
    woocommerce_api_secret = os.environ.get("KLAVIS_WOOCOMMERCE_CONSUMER_SECRET", "cs_woocommerce_token_Ttorres9177j"),
    woocommerce_site_url = os.environ.get("KLAVIS_WOOCOMMERCE_SITE_URL", "http://localhost:10003/store85"),
    
    woocommerce_admin_username = os.environ.get("KLAVIS_WOOCOMMERCE_ADMIN_USERNAME", "mcpwoocommerce"),
    woocommerce_admin_password = os.environ.get("KLAVIS_WOOCOMMERCE_ADMIN_PASSWORD", "mcpwoocommerce"),

)