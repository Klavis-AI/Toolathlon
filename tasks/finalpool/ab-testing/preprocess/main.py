from argparse import ArgumentParser
import os
import sys
import subprocess
import json
from pathlib import Path
from google.oauth2 import service_account
from .ggcloud_clean_log import clean_log
from .ggcloud_clean_dataset import clean_dataset  
from .ggcloud_clean_bucket import clean_bucket
from .ggcloud_upload import upload_csvs_to_bigquery
from google.oauth2.credentials import Credentials
from .utils import get_project_id


if __name__ == "__main__":
    parser = ArgumentParser()
    parser.add_argument("--agent_workspace", required=True)
    parser.add_argument("--credentials_file", required=False, default="configs/gcp-service_account.keys.json")
    parser.add_argument("--launch_time", required=False, help="Launch time")
    args = parser.parse_args()
    
    credentials_file = "configs/google_cloud_credentials.json"
    with open(credentials_file, 'r') as f:
        cred_data = json.load(f)
    scopes = cred_data.get('scope', '').split()
    credentials = Credentials(
        token=cred_data['access_token'],
        refresh_token=cred_data['refresh_token'],
        token_uri="https://oauth2.googleapis.com/token",
        client_id=cred_data['client_id'],
        client_secret=cred_data['client_secret'],
        scopes=scopes
    )

    project_id = get_project_id(credentials)
    print(f"Using project: {project_id}")

    print("=================  clean log =================")
    clean_log(project_id, credentials)

    print("=================  clean dataset =================")
    clean_dataset(project_id, credentials)
    
    print("=================  clean bucket =================")
    clean_bucket(project_id, credentials)

    print("======== wait 10s to make sure that the dataset is configured")
    from time import sleep
    sleep(10)

    print("=================  upload files =================")
    upload_csvs_to_bigquery(
        project_id=project_id,
        dataset_id="ab_testing",
        csv_folder=f"{Path(__file__).parent.resolve()}/../files",
        csv_pattern="*.csv",
        credentials=credentials
    )