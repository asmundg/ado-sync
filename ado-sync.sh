#!/bin/bash

# git setup:
#   - git config --global ado.homeOrg https://dev.azure.com/ADO_HOME_ORG (name of home ADO tenant, typically msfast)
#   - git config ado.project PROJECT (name of repo project, e.g. Personal)
#   - git config ado.extraFields '["Priority=2"]' (depending on work item requirements for your particular org/repo)

# Show work items from home backlog
function ado_show_home_work_items() {
    az boards query --organization "$(ado_home_org)" --wiql "$(my_work_wiql)" | jq -r '.[].fields  | [."System.Id", ."System.Title"] | join(" ")'
}

# Show work items from repo org backlog
function ado_show_repo_work_items() {
    az boards query --detect true --wiql "$(my_work_wiql)" | jq -r '.[].fields  | [."System.Id", ."System.Title"] | join(" ")'
}

function ado_dump_work_item() {
    ID=$1
    WI_FILE=$(mktemp)
    az boards work-item show --id "$ID" --organization "$(ado_home_org)" >"$WI_FILE"
    echo "$WI_FILE"
}

function ado_show_unlinked() {
    az boards query --organization "$(ado_home_org)" --wiql "$(my_work_wiql)" | jq -r '.[].fields."System.Id"' | while read -r id; do
        WI_FILE=$(mktemp)
        az boards work-item show --id "$id" --organization "$(ado_home_org)" >"$WI_FILE"

        if ! jq '.relations[] | select( .attributes.name == "Remote Related")' "$WI_FILE" | grep -q '.*'; then
            TITLE="$(jq -r '.fields."System.Title"' "$WI_FILE")"
            echo "$id $TITLE"
        fi
    done
}

# Create a repo backlog item from a home org work item
function ado_link() {
    ID=$1
    ADO_PROJECT=${ADO_PROJECT:-$(git config ado.project)}
    if [ -z "$ADO_PROJECT" ]; then
        echo >&2 "git config ado.project undefined!"
        return
    fi

    # Null-terminate fields to avoid xargs trying to be clever
    EXTRA_FIELDS=$(git config ado.extraFields | jq -r '.[] | .' | tr \\n \\0)

    WI_FILE=$(ado_dump_work_item "$ID")
    TITLE="$(jq -r '.fields."System.Title"' "$WI_FILE")"
    TYPE="Task"
    REMOTE_URL="$(az boards work-item show --id "$ID" --organization "$(ado_home_org)" | jq -r '.url')"
    USER="$(az ad signed-in-user show | jq -r .userPrincipalName)"

    NEW_WI_FILE=$(mktemp)
    if [ -n "$EXTRA_FIELDS" ]; then
        echo -n "$EXTRA_FIELDS" | xargs -0 az boards work-item create --detect true --title "$TITLE" --type "$TYPE" --assigned-to "$USER" --project "$ADO_PROJECT" --fields >"$NEW_WI_FILE"
    else
        az boards work-item create --detect true --title "$TITLE" --type "$TYPE" --assigned-to "$USER" --project "$ADO_PROJECT" >"$NEW_WI_FILE"
    fi

    NEW_ID="$(jq -r '.id' "$NEW_WI_FILE")"
    az boards work-item relation add --detect true --id "$NEW_ID" --relation-type "Remote Related" --target-url "$REMOTE_URL"
}

function ado_home_org() {
    echo "${ADO_HOME_ORG:-$(git config ado.homeOrg)}"
}

function my_work_wiql() {
    echo "SELECT [System.Id], [System.Title], [System.State] FROM workitems WHERE [System.AssignedTo]  = @me AND [System.State] NOT IN ('Done', 'Removed', 'Will not fix', 'Closed', 'Resolved')"
}
