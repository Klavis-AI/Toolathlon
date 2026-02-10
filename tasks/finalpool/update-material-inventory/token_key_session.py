from addict import Dict
import os

file_path = os.path.abspath(__file__)

folder_id_file = os.path.join(os.path.dirname(file_path), "files", "folder_id.txt")
with open(folder_id_file, "r") as f:
    folder_id = f.read().strip()

all_token_key_session = Dict(
    
    woocommerce_api_key = os.environ.get("KLAVIS_WOOCOMMERCE_CONSUMER_KEY", "ck_woocommerce_token_barbg4XESRzo"),
    woocommerce_api_secret = os.environ.get("KLAVIS_WOOCOMMERCE_CONSUMER_SECRET", "cs_woocommerce_token_barbg4XESRzo"),
    woocommerce_site_url = os.environ.get("KLAVIS_WOOCOMMERCE_SITE_URL", "http://localhost:10003/store91"),

    google_sheets_folder_id = folder_id,
)