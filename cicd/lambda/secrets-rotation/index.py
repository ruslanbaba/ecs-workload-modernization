import json
import boto3
import os
import logging
import random
import string
from datetime import datetime, timedelta
from typing import Dict, Any

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
secrets_client = boto3.client('secretsmanager')
ssm_client = boto3.client('ssm')
kms_client = boto3.client('kms')

def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    AWS Lambda handler for automated secrets rotation
    """
    try:
        logger.info(f"Starting secrets rotation process: {json.dumps(event)}")
        
        # Get KMS key ID from environment
        kms_key_id = os.environ.get('KMS_KEY_ID')
        if not kms_key_id:
            raise ValueError("KMS_KEY_ID environment variable not set")
        
        # Rotate secrets based on event type
        if 'source' in event and event['source'] == 'aws.events':
            # Scheduled rotation
            results = rotate_scheduled_secrets(kms_key_id)
        elif 'SecretId' in event:
            # Manual rotation triggered by Secrets Manager
            results = rotate_specific_secret(event['SecretId'], kms_key_id)
        else:
            # Default: rotate all applicable secrets
            results = rotate_all_secrets(kms_key_id)
        
        logger.info(f"Secrets rotation completed successfully: {results}")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Secrets rotation completed successfully',
                'results': results,
                'timestamp': datetime.utcnow().isoformat()
            })
        }
        
    except Exception as e:
        logger.error(f"Error during secrets rotation: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'timestamp': datetime.utcnow().isoformat()
            })
        }

def rotate_scheduled_secrets(kms_key_id: str) -> Dict[str, Any]:
    """
    Rotate secrets that are due for scheduled rotation
    """
    results = {
        'rotated_secrets': [],
        'skipped_secrets': [],
        'failed_secrets': []
    }
    
    try:
        # List all secrets with the specific prefix
        paginator = secrets_client.get_paginator('list_secrets')
        
        for page in paginator.paginate():
            for secret in page['SecretList']:
                secret_name = secret['Name']
                
                # Only rotate secrets in our namespace
                if not secret_name.startswith('ecs-modernization/'):
                    continue
                
                # Check if secret needs rotation
                if should_rotate_secret(secret):
                    try:
                        rotate_result = rotate_secret_by_type(secret_name, kms_key_id)
                        results['rotated_secrets'].append({
                            'name': secret_name,
                            'result': rotate_result
                        })
                        logger.info(f"Successfully rotated secret: {secret_name}")
                    except Exception as e:
                        logger.error(f"Failed to rotate secret {secret_name}: {str(e)}")
                        results['failed_secrets'].append({
                            'name': secret_name,
                            'error': str(e)
                        })
                else:
                    results['skipped_secrets'].append(secret_name)
                    logger.info(f"Skipped secret (not due for rotation): {secret_name}")
    
    except Exception as e:
        logger.error(f"Error listing secrets: {str(e)}")
        raise
    
    return results

def rotate_specific_secret(secret_id: str, kms_key_id: str) -> Dict[str, Any]:
    """
    Rotate a specific secret
    """
    try:
        result = rotate_secret_by_type(secret_id, kms_key_id)
        return {
            'secret_id': secret_id,
            'result': result,
            'status': 'success'
        }
    except Exception as e:
        logger.error(f"Failed to rotate specific secret {secret_id}: {str(e)}")
        return {
            'secret_id': secret_id,
            'error': str(e),
            'status': 'failed'
        }

def rotate_all_secrets(kms_key_id: str) -> Dict[str, Any]:
    """
    Rotate all applicable secrets
    """
    return rotate_scheduled_secrets(kms_key_id)

def should_rotate_secret(secret: Dict[str, Any]) -> bool:
    """
    Determine if a secret should be rotated based on last rotation date
    """
    # Get last rotation date
    last_changed = secret.get('LastChangedDate')
    if not last_changed:
        return True  # Never been rotated
    
    # Check if it's been more than 90 days since last rotation
    rotation_threshold = datetime.utcnow() - timedelta(days=90)
    return last_changed < rotation_threshold

def rotate_secret_by_type(secret_name: str, kms_key_id: str) -> Dict[str, Any]:
    """
    Rotate secret based on its type and content
    """
    try:
        # Get current secret value
        response = secrets_client.get_secret_value(SecretId=secret_name)
        current_secret = json.loads(response['SecretString'])
        
        # Determine secret type and rotate accordingly
        if 'database' in secret_name:
            return rotate_database_secret(secret_name, current_secret, kms_key_id)
        elif 'api-secrets' in secret_name:
            return rotate_api_secret(secret_name, current_secret, kms_key_id)
        elif 'jwt' in secret_name or 'api' in secret_name:
            return rotate_token_secret(secret_name, current_secret, kms_key_id)
        else:
            # Generic rotation for other secret types
            return rotate_generic_secret(secret_name, current_secret, kms_key_id)
            
    except Exception as e:
        logger.error(f"Error rotating secret {secret_name}: {str(e)}")
        raise

def rotate_database_secret(secret_name: str, current_secret: Dict[str, Any], kms_key_id: str) -> Dict[str, Any]:
    """
    Rotate database credentials
    """
    # Generate new password
    new_password = generate_secure_password(32)
    
    # Update the secret with new password
    new_secret = current_secret.copy()
    new_secret['password'] = new_password
    
    # Store the new secret
    secrets_client.update_secret(
        SecretId=secret_name,
        SecretString=json.dumps(new_secret),
        KmsKeyId=kms_key_id
    )
    
    logger.info(f"Rotated database secret: {secret_name}")
    return {
        'type': 'database',
        'action': 'password_rotated',
        'timestamp': datetime.utcnow().isoformat()
    }

def rotate_api_secret(secret_name: str, current_secret: Dict[str, Any], kms_key_id: str) -> Dict[str, Any]:
    """
    Rotate API secrets (JWT, encryption keys, etc.)
    """
    new_secret = current_secret.copy()
    
    # Rotate JWT secret
    if 'jwt_secret' in new_secret:
        new_secret['jwt_secret'] = generate_secure_token(64)
    
    # Rotate API key
    if 'api_key' in new_secret:
        new_secret['api_key'] = generate_api_key()
    
    # Rotate encryption key
    if 'encrypt_key' in new_secret:
        new_secret['encrypt_key'] = generate_secure_token(32)
    
    # Rotate webhook secret
    if 'webhook_secret' in new_secret:
        new_secret['webhook_secret'] = generate_secure_token(32)
    
    # Store the new secret
    secrets_client.update_secret(
        SecretId=secret_name,
        SecretString=json.dumps(new_secret),
        KmsKeyId=kms_key_id
    )
    
    logger.info(f"Rotated API secret: {secret_name}")
    return {
        'type': 'api_secret',
        'action': 'keys_rotated',
        'timestamp': datetime.utcnow().isoformat()
    }

def rotate_token_secret(secret_name: str, current_secret: Dict[str, Any], kms_key_id: str) -> Dict[str, Any]:
    """
    Rotate token-based secrets
    """
    new_secret = current_secret.copy()
    
    # Rotate token
    if 'token' in new_secret:
        new_secret['token'] = generate_secure_token(64)
    
    # Store the new secret
    secrets_client.update_secret(
        SecretId=secret_name,
        SecretString=json.dumps(new_secret),
        KmsKeyId=kms_key_id
    )
    
    logger.info(f"Rotated token secret: {secret_name}")
    return {
        'type': 'token',
        'action': 'token_rotated',
        'timestamp': datetime.utcnow().isoformat()
    }

def rotate_generic_secret(secret_name: str, current_secret: Dict[str, Any], kms_key_id: str) -> Dict[str, Any]:
    """
    Generic rotation for other secret types
    """
    # Log that this secret was reviewed but not rotated
    logger.info(f"Reviewed secret {secret_name} - no automatic rotation configured")
    return {
        'type': 'generic',
        'action': 'reviewed_only',
        'timestamp': datetime.utcnow().isoformat()
    }

def generate_secure_password(length: int = 32) -> str:
    """
    Generate a secure password with mixed case, numbers, and symbols
    """
    characters = string.ascii_letters + string.digits + "!@#$%^&*"
    password = ''.join(random.choice(characters) for _ in range(length))
    
    # Ensure password contains at least one of each character type
    if not any(c.islower() for c in password):
        password = password[:-1] + random.choice(string.ascii_lowercase)
    if not any(c.isupper() for c in password):
        password = password[:-1] + random.choice(string.ascii_uppercase)
    if not any(c.isdigit() for c in password):
        password = password[:-1] + random.choice(string.digits)
    if not any(c in "!@#$%^&*" for c in password):
        password = password[:-1] + random.choice("!@#$%^&*")
    
    return password

def generate_secure_token(length: int = 64) -> str:
    """
    Generate a secure token for API keys and secrets
    """
    characters = string.ascii_letters + string.digits
    return ''.join(random.choice(characters) for _ in range(length))

def generate_api_key() -> str:
    """
    Generate a formatted API key
    """
    prefix = "ecs_mod"
    key_part = generate_secure_token(32)
    return f"{prefix}_{key_part}"

def notify_rotation_completion(secret_name: str, rotation_result: Dict[str, Any]) -> None:
    """
    Send notification about completed rotation (placeholder for SNS integration)
    """
    # This could be extended to send SNS notifications or update external systems
    logger.info(f"Rotation notification for {secret_name}: {rotation_result}")

def validate_secret_rotation(secret_name: str) -> bool:
    """
    Validate that the secret rotation was successful
    """
    try:
        # Try to retrieve the secret to ensure it's accessible
        response = secrets_client.get_secret_value(SecretId=secret_name)
        secret_value = json.loads(response['SecretString'])
        
        # Basic validation that the secret is properly formatted
        if isinstance(secret_value, dict) and secret_value:
            return True
        return False
        
    except Exception as e:
        logger.error(f"Validation failed for secret {secret_name}: {str(e)}")
        return False
