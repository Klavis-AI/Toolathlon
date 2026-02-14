from addict import Dict
import os
import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..')))
from utils.app_specific.poste.domain_utils import domain_str
# I am gradually modifying the tokens to the pseudo account in this project

file_path = os.path.abspath(__file__)



emails_config_file = os.path.join(os.path.dirname(file_path),  "files" ,"poste.json")



all_token_key_session = Dict( 

 # use local deployed ones, or set up your own token to control
    canvas_api_token = "canvas_token_Zedwards5385",
    admin_canvas_token = "mcpcanvasadmintoken2",
    emails_config_file = emails_config_file,
    admin_email_address = domain_str("mcpcanvasadmin2"),
    admin_email_password = "mcpcanvasadminpass2",

)