from addict import Dict
import os
import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..')))
from utils.app_specific.poste.domain_utils import domain_str
# I am gradually modifying the tokens to the pseudo account in this project
all_token_key_session = Dict( 

 # use local deployed ones, or set up your own token to control
    canvas_user_name = domain_str("ryan.brown93"),
    canvas_api_token = "canvas_token_BryapivvLK7C",
    admin_canvas_token = "mcpcanvasadmintoken2"
 
)