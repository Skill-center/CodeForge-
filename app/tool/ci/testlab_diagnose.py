#!/usr/bin/env python3
"""Why Test Lab refuses CI's key (Phase 4; docs/BUILD_AND_RELEASE.md §4).

ci.yml's testlab job runs this only when listing Test Lab's phones failed,
so it costs no test. It reads the key that google-github-actions/auth wrote
(GOOGLE_APPLICATION_CREDENTIALS) and the project id (PROJECT), asks gcloud
what the key can see in the project, and prints key=value lines ending in
one hint. It never prints a project id or the key: only yes or no for the
ids, the account's name before the @, its roles on the project and the two
APIs. (The job's commit step also replaces the project id in the evidence.)

  python3 app/tool/ci/testlab_diagnose.py              # in the job
  python3 app/tool/ci/testlab_diagnose.py --self-test
"""
import json
import os
import re
import subprocess
import sys

APIS = ("testing.googleapis.com", "toolresults.googleapis.com")

# Roles that let an account run Test Lab with its default results bucket
# (Firebase's IAM reference; BUILD_AND_RELEASE §4 asks for Editor).
TEST_LAB_ROLES = {"roles/owner", "roles/editor"}

# A Google Cloud project id: 6 to 30 characters, lower case letters, digits
# and hyphens, starting with a letter. A project's name or number is not one.
PROJECT_ID = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")


def gcloud(*args):
    """gcloud's output, or None and its last error line."""
    try:
        done = subprocess.run(
            ["gcloud", *args], capture_output=True, text=True, timeout=120
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error)
    if done.returncode != 0:
        lines = [line.strip() for line in done.stderr.splitlines() if line.strip()]
        return None, lines[-1] if lines else "exit %d" % done.returncode
    return done.stdout, None


def hint(facts):
    """The one thing to fix first, from what was found."""
    if not facts["project_format_ok"]:
        return (
            "FIREBASE_PROJECT_ID does not look like a project id. It must be the "
            "id (Firebase console > Project settings > Project ID, such as "
            "codeforge-1a2b3), not the project's name or number, with no spaces"
        )
    if facts["key_type"] != "service_account":
        return (
            "FIREBASE_TEST_LAB_KEY is not a service account's JSON key. Create one: "
            "Google Cloud console > IAM & Admin > Service accounts > the account > "
            "Keys > Add key > JSON, and paste the whole file"
        )
    if facts["active_is_key"] is False:
        return "gcloud is not using the key's account; the job's authentication step needs a look"
    roles = facts["roles"]
    if roles is None or not (set(roles) & TEST_LAB_ROLES):
        where = (
            " The key belongs to another project: granting its account Editor on "
            "this project works too."
            if facts["key_project_matches"] is False
            else ""
        )
        return (
            "Give the service account the Editor role on the project itself: "
            "Google Cloud console > IAM & Admin > IAM > Grant access, New principals "
            "= the account's email (the key's client_email), Role = Basic > Editor, "
            "Save. A role given on the service account's own page does not count."
            + where
        )
    apis = facts["apis"]
    if apis is not None and not all(apis.get(api) for api in APIS):
        return (
            "Enable the Cloud Testing API and the Cloud Tool Results API in the "
            "project: Google Cloud console > APIs & Services > Library, search "
            "each name, Enable"
        )
    return (
        "The key, its role and the APIs look right. A new role can take a few "
        "minutes to apply: try the check again"
    )


def diagnose():
    project = os.environ.get("PROJECT", "")
    facts = {
        "project_format_ok": bool(PROJECT_ID.match(project)),
        "key_type": None,
        "key_project_matches": None,
        "active_is_key": None,
        "roles": None,
        "apis": None,
    }
    print("--- diagnosis (listing failed, so no test was used)")
    print("project_id_format=%s" % ("ok" if facts["project_format_ok"] else "unexpected"))
    if project != project.strip():
        print("project_id_whitespace=yes (spaces or a line break around it)")

    email = ""
    path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "")
    try:
        with open(path, encoding="utf-8") as handle:
            key = json.load(handle)
        facts["key_type"] = key.get("type")
        email = key.get("client_email", "")
        key_project = key.get("project_id", "")
        facts["key_project_matches"] = key_project == project.strip()
        print("key_type=%s" % facts["key_type"])
        print("key_project_matches_FIREBASE_PROJECT_ID=%s" % ("yes" if facts["key_project_matches"] else "no"))
        print("account=%s@... (from the key)" % email.split("@")[0])
    except (OSError, ValueError, AttributeError) as error:
        print("key=unreadable (%s)" % type(error).__name__)

    out, error = gcloud("auth", "list", "--filter=status:ACTIVE", "--format=value(account)")
    if out is not None and email:
        facts["active_is_key"] = out.strip() == email
        print("active_account_is_the_key=%s" % ("yes" if facts["active_is_key"] else "no"))

    if facts["project_format_ok"] and email:
        out, error = gcloud(
            "projects", "get-iam-policy", project.strip(),
            "--flatten=bindings[].members",
            "--filter=bindings.members:serviceAccount:%s" % email,
            "--format=value(bindings.role)",
        )
        if out is None:
            print("roles_on_project=unreadable (%s)" % error)
        else:
            facts["roles"] = sorted(set(out.split()))
            print("roles_on_project=%s" % (",".join(facts["roles"]) or "none"))

        out, error = gcloud(
            "services", "list", "--enabled", "--project", project.strip(),
            "--format=value(config.name)",
        )
        if out is None:
            print("apis=unreadable (%s)" % error)
        else:
            enabled = set(out.split())
            facts["apis"] = {api: api in enabled for api in APIS}
            for api in APIS:
                print("api_%s=%s" % (api, "enabled" if facts["apis"][api] else "not enabled"))

    print("hint=%s" % hint(facts))
    return 0


def self_test():
    base = {
        "project_format_ok": True,
        "key_type": "service_account",
        "key_project_matches": True,
        "active_is_key": True,
        "roles": ["roles/editor"],
        "apis": {api: True for api in APIS},
    }

    def case(**changes):
        facts = dict(base)
        facts.update(changes)
        return hint(facts)

    assert PROJECT_ID.match("codeforge-1a2b3")
    for bad in ("CodeForge", "codeforge 1", "123456789012", "abc", "codeforge-"):
        assert not PROJECT_ID.match(bad), bad
    assert "does not look like a project id" in case(project_format_ok=False)
    assert "not a service account" in case(key_type="authorized_user")
    assert "Editor role" in case(roles=None)
    assert "Editor role" in case(roles=["roles/viewer"])
    assert "another project" in case(roles=[], key_project_matches=False)
    assert "another project" not in case(roles=[])
    assert "Enable the Cloud Testing API" in case(
        apis={"testing.googleapis.com": False, "toolresults.googleapis.com": True}
    )
    assert "look right" in case()
    assert "look right" in case(roles=["roles/owner"], apis=None)
    print("testlab_diagnose self-test: OK (11 cases)")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv[1:] else diagnose())
