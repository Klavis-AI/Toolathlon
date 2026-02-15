from googleapiclient.discovery import build


def _extract_project_id(project):
    """Extract project ID from a Resource Manager project resource."""
    project_name = project.get("name", "")
    if "/" in project_name:
        return project_name.split("/")[-1]
    return project.get("projectId")


def get_project_id(credentials) -> str:
    """Fetch the project ID from Google Cloud Resource Manager API.

    If there is only one project, return it. If there are multiple projects,
    return the one whose project ID matches the email prefix of the account.
    Falls back to the first project if no match is found.
    """
    crm = build('cloudresourcemanager', 'v3', credentials=credentials)
    response = crm.projects().search().execute()
    projects = response.get("projects", [])
    if not projects:
        return None
    if len(projects) == 1:
        return _extract_project_id(projects[0])

    # Multiple projects: find the one matching the account's email prefix
    try:
        oauth2 = build('oauth2', 'v2', credentials=credentials)
        userinfo = oauth2.userinfo().get().execute()
        email = userinfo.get("email", "")
        email_prefix = email.split("@")[0] if email else ""
    except Exception:
        email_prefix = ""

    if email_prefix:
        for project in projects:
           if project.get("displayName", "") == email_prefix:
                return project.get("projectId")

    # Fallback to first project
    return _extract_project_id(projects[0])
