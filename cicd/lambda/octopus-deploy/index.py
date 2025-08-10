# DEPRECATED: This file has been removed as part of Octopus Deploy elimination
# 
# As of August 2025, all Octopus Deploy functionality has been replaced 
# with direct CodePipeline to ECS deployment for simplified CI/CD architecture.
#
# Previous functionality:
# - Octopus Deploy release creation
# - Environment-specific deployments
# - Application variable management
#
# Current replacement:
# - Direct CodePipeline to ECS deployment via buildspec files
# - AWS Parameter Store and Secrets Manager for configuration
# - ECS service updates through AWS CodeDeploy
#
# For migration details, see:
# - docs/CI_CD_SIMPLIFICATION.md
# - docs/OCTOPUS_REMOVAL_COMPLETE.md
# - cicd/buildspec/ directory for current deployment scripts
#
# This directory should be removed in the next cleanup cycle.
    for space in spaces_response.json()['Items']:
        if space['Name'] == space_name:
            space_id = space['Id']
            break
    
    if not space_id:
        raise Exception(f"Space '{space_name}' not found")
    
    # Get project ID
    projects_url = f"{server_url}/api/{space_id}/projects"
    projects_response = requests.get(projects_url, headers=headers)
    projects_response.raise_for_status()
    
    project_id = None
    for project in projects_response.json()['Items']:
        if project['Name'] == project_name:
            project_id = project['Id']
            break
    
    if not project_id:
        raise Exception(f"Project '{project_name}' not found")
    
    # Create release
    release_data = {
        'ProjectId': project_id,
        'Version': version,
        'ReleaseNotes': f'Automated release created by AWS CodePipeline\nImage URI: {image_uri}',
        'SelectedPackages': []
    }
    
    releases_url = f"{server_url}/api/{space_id}/releases"
    release_response = requests.post(releases_url, headers=headers, json=release_data)
    release_response.raise_for_status()
    
    return release_response.json()

def deploy_release(
    server_url: str,
    api_key: str,
    space_id: str,
    release_id: str,
    environment_name: str
) -> Dict[str, Any]:
    """Deploy a release to specified environment"""
    
    headers = {
        'X-Octopus-ApiKey': api_key,
        'Content-Type': 'application/json'
    }
    
    # Get environment ID
    environments_url = f"{server_url}/api/{space_id}/environments"
    environments_response = requests.get(environments_url, headers=headers)
    environments_response.raise_for_status()
    
    environment_id = None
    for env in environments_response.json()['Items']:
        if env['Name'] == environment_name:
            environment_id = env['Id']
            break
    
    if not environment_id:
        raise Exception(f"Environment '{environment_name}' not found")
    
    # Create deployment
    deployment_data = {
        'ReleaseId': release_id,
        'EnvironmentId': environment_id,
        'Comments': f'Automated deployment to {environment_name} via AWS CodePipeline'
    }
    
    deployments_url = f"{server_url}/api/{space_id}/deployments"
    deployment_response = requests.post(deployments_url, headers=headers, json=deployment_data)
    deployment_response.raise_for_status()
    
    return deployment_response.json()

def wait_for_deployment(
    server_url: str,
    api_key: str,
    space_id: str,
    deployment_id: str,
    timeout_minutes: int = 15
) -> bool:
    """Wait for deployment to complete"""
    
    import time
    
    headers = {
        'X-Octopus-ApiKey': api_key,
        'Content-Type': 'application/json'
    }
    
    start_time = time.time()
    timeout_seconds = timeout_minutes * 60
    
    while time.time() - start_time < timeout_seconds:
        deployment_url = f"{server_url}/api/{space_id}/deployments/{deployment_id}"
        response = requests.get(deployment_url, headers=headers)
        response.raise_for_status()
        
        deployment = response.json()
        state = deployment.get('State', '')
        
        logger.info(f"Deployment {deployment_id} state: {state}")
        
        if state in ['Success', 'Failed', 'Canceled', 'TimedOut']:
            return state == 'Success'
        
        time.sleep(30)  # Wait 30 seconds before checking again
    
    logger.error(f"Deployment {deployment_id} timed out after {timeout_minutes} minutes")
    return False

def handler(event, context):
    """Lambda handler for Octopus Deploy integration"""
    
    try:
        logger.info(f"Received event: {json.dumps(event)}")
        
        # Extract CodePipeline job data
        job = event.get('CodePipeline.job', {})
        job_id = job.get('id')
        user_parameters = json.loads(job.get('data', {}).get('actionConfiguration', {}).get('configuration', {}).get('UserParameters', '{}'))
        
        # Get configuration from environment and parameters
        server_url = os.environ['OCTOPUS_SERVER_URL']
        space_name = os.environ['OCTOPUS_SPACE_NAME']
        
        project_name = user_parameters.get('project', '')
        environment_name = user_parameters.get('environment', '')
        version = user_parameters.get('version', '')
        
        # Get API key from parameter store
        api_key = get_parameter('/ecs-modernization/octopus-api-key', encrypted=True)
        
        # Get image URI from input artifacts (this would be passed from the build stage)
        input_artifacts = job.get('data', {}).get('inputArtifacts', [])
        image_uri = f"123456789012.dkr.ecr.us-east-1.amazonaws.com/ecs-modernization/{project_name}:{version}"
        
        logger.info(f"Deploying {project_name} version {version} to {environment_name}")
        
        # Create release in Octopus Deploy
        release = create_octopus_release(
            server_url=server_url,
            api_key=api_key,
            space_name=space_name,
            project_name=project_name.upper() + "-System",  # Convert to project naming convention
            version=version,
            image_uri=image_uri
        )
        
        logger.info(f"Created release: {release['Id']}")
        
        # Deploy the release
        deployment = deploy_release(
            server_url=server_url,
            api_key=api_key,
            space_id=release['SpaceId'],
            release_id=release['Id'],
            environment_name=environment_name
        )
        
        logger.info(f"Started deployment: {deployment['Id']}")
        
        # Wait for deployment to complete
        success = wait_for_deployment(
            server_url=server_url,
            api_key=api_key,
            space_id=release['SpaceId'],
            deployment_id=deployment['Id'],
            timeout_minutes=15
        )
        
        if success:
            logger.info(f"Deployment {deployment['Id']} completed successfully")
            
            # Notify CodePipeline of success
            codepipeline = boto3.client('codepipeline')
            codepipeline.put_job_success_result(jobId=job_id)
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'message': 'Deployment successful',
                    'releaseId': release['Id'],
                    'deploymentId': deployment['Id']
                })
            }
        else:
            logger.error(f"Deployment {deployment['Id']} failed")
            
            # Notify CodePipeline of failure
            codepipeline = boto3.client('codepipeline')
            codepipeline.put_job_failure_result(
                jobId=job_id,
                failureDetails={'message': 'Octopus Deploy deployment failed', 'type': 'JobFailed'}
            )
            
            return {
                'statusCode': 500,
                'body': json.dumps({
                    'message': 'Deployment failed',
                    'releaseId': release['Id'],
                    'deploymentId': deployment['Id']
                })
            }
            
    except Exception as e:
        logger.error(f"Error in Lambda handler: {str(e)}")
        
        # Notify CodePipeline of failure if job_id is available
        if 'job_id' in locals():
            codepipeline = boto3.client('codepipeline')
            codepipeline.put_job_failure_result(
                jobId=job_id,
                failureDetails={'message': str(e), 'type': 'JobFailed'}
            )
        
        return {
            'statusCode': 500,
            'body': json.dumps({
                'message': f'Error: {str(e)}'
            })
        }
