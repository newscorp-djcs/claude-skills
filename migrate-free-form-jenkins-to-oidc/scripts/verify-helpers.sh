#!/bin/bash
# Offline check of the Artifactory OIDC helper block inside a Jenkinsfile:
#   1) whole Jenkinsfile parses as Groovy   2) token + Basic-auth form are masked in output
#   3) exit codes pass through              4) failed exchange stops before the script runs
#   5) helper block has no calls that need Jenkins script approval
#   6) both scopes mint a token, each with its own STS audience and JFrog provider (ro is the default)
# Usage: verify-helpers.sh <path/to/Jenkinsfile>      Needs: groovy, bash, jq
set -euo pipefail
JF=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BASH_BIN=$(command -v bash)

# 1) parse check (@NonCPS is Jenkins-only, strip it)
sed 's/^@NonCPS//' "$JF" > "$WORK/Jenkinsfile.groovy"
cat > "$WORK/parse.groovy" <<'G'
new GroovyShell().parse(new File(args[0]).text); println "PARSE: OK"
G
groovy "$WORK/parse.groovy" "$WORK/Jenkinsfile.groovy"

# 2-4) run the real helper block with stubbed Jenkins steps and mocked aws/curl
sed -n '/^\/\/ BEGIN Artifactory/,/^\/\/ END Artifactory/p' "$JF" | sed 's/^@NonCPS//' > "$WORK/helpers.groovy"
[ -s "$WORK/helpers.groovy" ] || { echo "No '// BEGIN Artifactory' ... '// END Artifactory' block in $JF"; exit 1; }

# sandbox check: calls that trigger Jenkins In-process Script Approval must not appear in helper code
if grep -v '^ *//' "$WORK/helpers.groovy" | grep -n -E '\.bytes|getBytes|encodeBase64|decodeBase64|new String|JsonOutput|JsonSlurper|java\.util\.Base64|\.execute\(|padRight|intdiv'; then
    echo "SANDBOX: FAILED - the lines above need script approval; do that work in a shQuiet one-liner"; exit 1
fi
echo "SANDBOX: OK (no known approval-requiring calls in the helper block)"
{
cat <<G
class Stop extends RuntimeException { Stop(String m) { super(m) } }
envOverlay = [:]
def withEnv(List l, Closure c) { def saved = envOverlay.clone(); l.each { def s = it.toString(); def i = s.indexOf('='); envOverlay[s.substring(0, i)] = s.substring(i + 1) }; try { c() } finally { envOverlay = saved } }
def echo(m) { println m }
def error(m) { throw new Stop(m.toString()) }
def sh(Map a) {
    def f = File.createTempFile('jfsh', '.sh', new File('$WORK')); f.text = a.script
    def pb = new ProcessBuilder(a.script.startsWith('#!') ? ['$BASH_BIN', f.path] : ['$BASH_BIN', '-xe', f.path])
    pb.environment().putAll(envOverlay); pb.environment()['PATH'] = '$HERE/mocks:' + System.getenv('PATH')
    def p = pb.start(); def out = p.inputStream.text; System.err.print(p.errorStream.text); p.waitFor()
    return a.returnStdout ? out : p.exitValue()
}
G
cat "$WORK/helpers.groovy"
cat <<'G'
def failures = []
def captured = new ByteArrayOutputStream(); def orig = System.out
System.setOut(new PrintStream(captured, true))
def rc
try {
    rc = shWithArtifactoryToken('rw', 'echo "TRACE password=$ARTIFACTORY_PASSWORD" >&2; echo "Authorization: Basic $(printf %s:%s "$ARTIFACTORY_USERNAME" "$ARTIFACTORY_PASSWORD" | base64 | tr -d "\\n")"; set +e; exit 2')
} finally { System.setOut(orig) }
def log = captured.toString()
println log
if (log.contains('NOT-A-REAL-SIGNATURE')) failures << 'raw Artifactory token leaked'
if (log.contains('MOCK-AWS-WEB-IDENTITY-TOKEN')) failures << 'AWS web identity token leaked'
if (!log.contains('Authorization: Basic ****')) failures << 'Basic-auth header not masked'
if (rc != 2) failures << "exit code not passed through (got ${rc})"
captured = new ByteArrayOutputStream(); System.setOut(new PrintStream(captured, true))
try { rc = shWithArtifactoryToken('ro', 'echo "RO_RAN"') } finally { System.setOut(orig) }
log = captured.toString(); println log
if (rc != 0 || !log.contains('RO_RAN')) failures << "ro script did not run (rc ${rc})"
if (!log.contains("'ro' token for aws-iam-ro-")) failures << 'ro scope did not use the aws-iam-ro provider'
def awsLog = new File(System.getenv('MOCK_AWS_LOG')).text
['RO', 'RW'].each { if (!awsLog.contains("--audience DJ-Artifactory-${it}")) failures << "no STS call with audience DJ-Artifactory-${it}" }
try { withEnv(['FAIL_SCOPE=ro']) { shWithArtifactoryToken('ro', 'echo SHOULD_NOT_RUN') }; failures << 'failed exchange did not stop' }
catch (Stop e) { println "Expected failure: ${e.message}" }
println(failures ? "VERIFY: FAILED ${failures}" : 'VERIFY: OK (masking, exit code, ro and rw scopes, fail-closed)')
if (failures) System.exit(1)
G
} > "$WORK/run.groovy"
(cd "$WORK" && MOCK_AWS_LOG="$WORK/aws.log" groovy run.groovy)
