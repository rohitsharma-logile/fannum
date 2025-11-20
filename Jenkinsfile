def jsonLP = null;
def jsonWFM = null;
def chosen = null;

// Store misc things here
def temp = [:];

pipeline {
    agent any
	
    options {
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
    }

    parameters {
        choice(name: 'PRODUCT_MODULE', choices: ['lp', 'wfm'])
        choice(name: 'ACTION', choices: ['start', 'stop'])
    }
    
    environment {
        REPO = 'https://github.com/rohitsharma-logile/fannum.git'
        SSH_CRED = 'AWS_EC2_KEY'
        GITHUB_CRED = 'GITHUB_APP_PASSWORD'
        MAX_WAIT_SEC = 480
        STARTUP_WAIT_SEC = 5
        CHECK_INTERVAL_SEC = 20
    }

    stages {
        stage('Clone repo') {
            steps {
                 script {
                     checkout([
                         $class: 'GitSCM',
                         branches: [[name: '*/main']],
                         userRemoteConfigs: [[
                            url: env.REPO,
                            credentialsId: env.GITHUB_CRED
                         ]]
                     ])
                 }
            }
        }

        stage('Parse JSON') {
            steps {
                script {
                    jsonLP = safeParse('lp_mapper.json')
                    jsonWFM = safeParse('wfm_mapper.json')
                }
            }
        }

        stage('Prompt target') {
            steps {
                script {
                    def chosenModulesJSON = (params.PRODUCT_MODULE == 'lp' ? jsonLP : jsonWFM)
                    if (chosenModulesJSON == null) {
                        error("No JSON loaded for ${params.PRODUCT_MODULE}")
                    }

                    def selected = input(
                        message: 'Select a target',
                        parameters: [
                            choice(name: 'TARGET', choices: chosenModulesJSON.keySet().join('\n'))
                        ]
                    )

                    if (!chosenModulesJSON.containsKey(selected)) {
                        temp.err_msg = "Selected target doesn't exist in ${params.PRODUCT_MODULE} JSON"
                        error(temp.err_msg)
                    }
                    
                    chosen = chosenModulesJSON[selected]
                    
                    def envMap = [:]
                    chosen.eachWithIndex { item, idx ->
                        envMap[item.env] = idx
                    }

                    
                    selected = input(
                        message: 'Select an environment',
                        parameters: [
                            choice(name: 'TARGET_ENV', choices: envMap.keySet().join('\n'))
                        ]
                    )
                    chosen = chosen[envMap[selected]]
                    temp.chosen_target = selected
                }
            }
        }

        stage('Perform action') {
            steps {
                script {
                    def output = ""
                    def action = params.ACTION
                    def scriptPath = (params.ACTION == "start") ? chosen.startScript : chosen.stopScript
                    
                    sshagent(credentials: [env.SSH_CRED]) {
                        try {
                            output = sh(
                                script: """scp -o StrictHostKeyChecking=no start_stop_script.sh ec2-user@${chosen.appServerIP}:/tmp/start_stop_script.sh""",
                                returnStdout: true
                            ).trim()
                            output = sh(
                                script: """ssh -o StrictHostKeyChecking=no ec2-user@${chosen.appServerIP} << 'EOF'
chmod +x /tmp/start_stop_script.sh
encoded_wildfly=\$(echo -n "${chosen.wildflyDir}" | base64 -w0)
/tmp/start_stop_script.sh "${chosen.appServerIP}" "\$encoded_wildfly" "${scriptPath}" "${params.PRODUCT_MODULE}" "${action}" "${env.MAX_WAIT_SEC}" "${env.CHECK_INTERVAL_SEC}"
EOF""",
                                returnStdout: true
                            ).trim()
                        } catch (Exception e) {
                            output = e.getMessage()
                        }
                    }
                    
                    if (output.contains('DEPLOY_STATUS:SUCCESS')) {
                        currentBuild.result = 'SUCCESS'
                    } else if (output.contains('DEPLOY_STATUS:TIMEOUT')) {
                        temp.err_msg = 'Timeout occured before deployment could finish'
                        error(temp.err_msg)
                    } else if (output.contains('DEPLOY_STATUS:NOFILE')) {
                        temp.err_msg = 'No indicator files available inside deployment folder'
                        error(temp.err_msg)
                    } else if (output.contains('DEPLOY_STATUS:START_FAILED')) {
                        temp.err_msg = "Start script failed: ${scriptPath}"
                        error(temp.err_msg)
                    } else if (output.contains('DEPLOY_STATUS:STOP_FAILED')) {
                        temp.err_msg = "Stop script failed: ${scriptPath}"
                        error(temp.err_msg)
                    } else {
                        temp.err_msg = output
                        error(temp.err_msg)
                    }
                }
            }
        }
        
        stage('Clear workspace') {
            steps { script { cleanWs() } }
        }
    }

    post {
        success {
            script {
                def name = temp.chosen_target ?: 'Unknown'
                def action = params.ACTION.toLowerCase()
                def state = (action == 'start' ? 'STARTED' : 'STOPPED')

                emailext(
                    to: 'rohit.sharma@logile.com',
                    subject: "SUCCESS: ${name} ${state} (${params.PRODUCT_MODULE})",
                    body: """Action: ${params.ACTION}
    Target: ${name}
    Application has been ${state.toLowerCase()} successfully."""
                )
            }
        }
        failure {
            script {
                def name = temp.chosen_target ?: 'Unknown'
                def reason = temp.err_msg ?: 'Unknown error'
                def action = params.ACTION.toLowerCase()
                def state = (action == 'start' ? 'START' : 'STOP')

                emailext(
                    to: 'rohit.sharma@logile.com',
                    subject: "FAILED: ${name} ${state} (${params.PRODUCT_MODULE})",
                    body: """Action: ${params.ACTION}
    Target: ${name}
    Reason: ${reason}"""
                )
            }
        }
    }
}

def safeParse(jsonPath) {
    try {
        return readJSON(file: jsonPath)
    } catch (Exception e) {
        error("Failed to parse JSON: ${e.message}")
    }
}
