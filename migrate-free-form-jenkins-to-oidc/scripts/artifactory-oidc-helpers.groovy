// BEGIN Artifactory short-lived token helpers
def getArtifactoryToken(String scope) {
    if (!(scope in ['ro', 'rw'])) {
        error "getArtifactoryToken: scope must be 'ro' or 'rw', got '${scope}'"
    }
    def account = shQuiet([], 'aws sts get-caller-identity --query Account --output text')
    def jwt = shQuiet([], "aws sts get-web-identity-token --audience DJ-Artifactory-${scope.toUpperCase()} --signing-algorithm RS256 --duration-seconds 300 --query WebIdentityToken --output text")
    if (!account.matches('[0-9]{12}') || !jwt.matches('[A-Za-z0-9._-]+')) {
        error "getArtifactoryToken: unexpected output from aws sts (account id or web identity token)"
    }
    def request = '{"grant_type":"urn:ietf:params:oauth:grant-type:token-exchange",' +
        '"subject_token_type":"urn:ietf:params:oauth:token-type:id_token",' +
        "\"subject_token\":\"${jwt}\",\"provider_name\":\"aws-iam-${scope}-${account}\"}"
    def resp = shQuiet(["ART_OIDC_REQUEST=${request}"],
        '''printf %s "$ART_OIDC_REQUEST" | curl -sS --max-time 30 -X POST -H 'Content-Type: application/json' -d @- https://artifactory.dowjones.io/access/api/v1/oidc/token''')
    def token = jsonField(resp, 'access_token') ?: error("No Artifactory '${scope}' token returned: ${jsonField(resp, 'message') ?: 'unexpected response'}")
    def claims = shQuiet(["ART_TOKEN=${token}"],
        '''p=$(printf %s "$ART_TOKEN" | cut -d. -f2 | tr '_-' '/+'); while [ $((${#p} % 4)) -ne 0 ]; do p="$p="; done; printf %s "$p" | base64 -d''')
    def user = jsonField(claims, 'sub')?.replaceFirst('^.*/users/', '') ?: error("Cannot read username from Artifactory '${scope}' token")
    return [username: user, token: token]
}

def shWithArtifactoryToken(String scope, String script) {
    def creds = getArtifactoryToken(scope)
    def credEnv = ["ARTIFACTORY_USERNAME=${creds.username}", "ARTIFACTORY_PASSWORD=${creds.token}"]
    def basicAuth = shQuiet(credEnv, '''printf %s:%s "$ARTIFACTORY_USERNAME" "$ARTIFACTORY_PASSWORD" | base64 | tr -d '\\n' ''')
    def secrets = [creds.token, basicAuth]
    echo "Using short-lived Artifactory '${scope}' token for ${creds.username}"
    def out
    withEnv(credEnv) {
        out = sh(returnStdout: true, script: "#!/bin/bash\n(\nset -xe\n${script}\n) 2>&1\necho \"__EXIT_CODE__=\$?\"")
    }
    def marker = out.lastIndexOf('__EXIT_CODE__=')
    def log = marker >= 0 ? out.substring(0, marker) : out
    secrets.each { log = log.replace(it, '****') }
    if (log.trim()) {
        echo log
    }
    return marker >= 0 ? Integer.parseInt(out.substring(marker + '__EXIT_CODE__='.length()).trim()) : 1
}

def shQuiet(List envVars, String script) {
    def out
    withEnv(envVars) {
        out = sh(returnStdout: true, script: "#!/bin/sh\n${script}")
    }
    return out.trim()
}

@NonCPS
def jsonField(String json, String field) {
    def m = json =~ /"${field}"\s*:\s*"([^"]*)"/
    return m.find() ? m.group(1) : null
}
// END Artifactory short-lived token helpers
