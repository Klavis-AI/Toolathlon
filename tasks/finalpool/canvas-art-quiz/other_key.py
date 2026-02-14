from addict import Dict
import os
import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..')))
from utils.app_specific.poste.domain_utils import domain_str
# this is the local token key session for local testing
# will override the token key session in the global ones in configs/token_key_session.py
all_token_key_session = Dict(
    canvas_admin_api_token = "mcpcanvasadmintoken3", 
    canvas_admin_domain = "localhost:10001",
    canvas_api_token = "canvas_token_brian1990$p1",

    # canvas_domain = "localhost:20001"
)

teacher_email = domain_str("bruiz")