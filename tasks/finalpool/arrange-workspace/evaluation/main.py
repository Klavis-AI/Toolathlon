
print("main.py started")
try:
    from argparse import ArgumentParser
    import asyncio
    import os
    import sys
    from .check_local import run_check_local
    from utils.general.helper import read_json  
except Exception as e:
    print("import error: ", e)
    exit(1)

print("import finished")


if __name__=="__main__":
    parser = ArgumentParser()
    print("args started")
    parser.add_argument("--agent_workspace", required=False)
    parser.add_argument("--groundtruth_workspace", required=False)
    parser.add_argument("--res_log_file", required=False)
    parser.add_argument("--launch_time", required=False, help="Launch time")
    args = parser.parse_args()
    # print(sys.argv, flush=True)
    
    res_log = read_json(args.res_log_file)

    # Download workspace files from Klavis local_dev sandbox if available
    sandbox_id = os.environ.get("TOOLATHLON_LOCAL_DEV_SANDBOX_ID")
    api_key = os.environ.get("KLAVIS_API_KEY")
    if sandbox_id and api_key:
        try:
            from utils.app_specific.local_dev.local_dev_sandbox import download_workspace
            download_workspace(sandbox_id, args.agent_workspace, api_key)
            print(f"[Klavis] Downloaded workspace from local_dev sandbox {sandbox_id}")
        except Exception as e:
            print(f"[Klavis] Failed to download workspace from local_dev sandbox: {e}")

    # check local
    try:
        print("agent_workspace: ", args.agent_workspace)
        local_pass, local_error = run_check_local(args.agent_workspace, args.groundtruth_workspace)
        if not local_pass:
            print("local check failed: ", local_error)
            exit(1)
    except Exception as e:
        print("local check error: ", e)
        exit(1)
    
    print("Pass all tests!")