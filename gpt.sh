#!/bin/bash

#bash script to run gpt-4o

#cd to the directory of the script
cd "$(dirname "$0")"

#load from env variable
if [ -f .gitpmoji.env ]; then
    source .gitpmoji.env
fi

# load from env variables
API_KEY=$GITPMOJI_API_KEY
API_BASE_URL=${GITPMOJI_API_BASE_URL:-https://api.openai.com/v1}
API_MODEL=${GITPMOJI_API_MODEL:-gpt-4o}
USE_BEDROCK=${GITPMOJI_USE_BEDROCK:-false}
AWS_REGION=${GITPMOJI_AWS_REGION:-us-east-1}
AWS_ACCESS_KEY_ID=${GITPMOJI_AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${GITPMOJI_AWS_SECRET_ACCESS_KEY}
BEDROCK_MODEL=${GITPMOJI_BEDROCK_MODEL:-anthropic.claude-3-7-sonnet-20250219-v1:0}

# check if API_KEY is set for OpenAI or if Bedrock credentials are set
if [ "$USE_BEDROCK" = "true" ]; then
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        echo "AWS credentials (GITPMOJI_AWS_ACCESS_KEY_ID and GITPMOJI_AWS_SECRET_ACCESS_KEY) are required when using Bedrock"
        exit 1
    fi
else
    if [ -z "$API_KEY" ]; then
        echo "GITPMOJI_API_KEY is not set"
        exit 1
    fi
fi

# check if jq is installed
if ! command -v jq &> /dev/null
then
    echo "jq could not be found, please install it"
    exit 1
fi

# check if aws cli is installed if using Bedrock
if [ "$USE_BEDROCK" = "true" ] && ! command -v aws &> /dev/null
then
    echo "AWS CLI could not be found, please install it"
    exit 1
fi

# Function to display help message
display_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h              Display this help message"
    echo "  -d              Pipe diff to stdin"
    echo "  -f DIFF.file    Specify the diff file. Will be used to generate the commit message"
    echo "  -g              Generate the commit message (and emoji)"
    echo "  -a              Assess the diff or file."
    echo "  -r              Give starts the rating of the assessment only"
    echo "  -w              Output the assessment in Markdown format"
    echo "  -m \"MESSAGE\"  Specify the commit message"
    echo "  -e              Will analyze message and add the emoji"
    echo "  -v              Verbose mode"
    echo
    echo "Example:"
    echo "  $0 -e -m \"Implement new feature\""
}

# Parse command line arguments
DIFF_CONTENT=""
DIFF_FILE=""
GENERATE=false
ASSESS=false
RATING=false
MARKDOWN=false
MESSAGE=""
RESULT=""
VERBOSE=false
EMOJI=false

while getopts "hdf:garwm:ev" opt; do
  case $opt in
    h)
      display_help
      exit 0
      ;;
    d)
      DIFF_CONTENT=$(cat)
      ;;
    f)
      DIFF_FILE="$OPTARG"
      ;;
    g)
      GENERATE=true
      ;;
    a)
      ASSESS=true
      ;;
    r)
      RATING=true
      ;;
    w)
      MARKDOWN=true
      ;;
    m)
      MESSAGE="$OPTARG"
      ;;
    e)
      EMOJI=true
      ;;
    v)
      VERBOSE=true
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      display_help
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      display_help
      exit 1
      ;;
  esac
done

# Shift the parsed options out of the argument list
shift $((OPTIND-1))

if [ "$VERBOSE" = true ]; then
  echo -e "DIFF_FILE: $DIFF_FILE"
  echo -e "DIFF_CONTENT: $DIFF_CONTENT"
  echo -e "ASSESS: $ASSESS"
  echo -e "RATING: $RATING"
  echo -e "MARKDOWN: $MARKDOWN"
  echo -e "MESSAGE: $MESSAGE"
  echo -e "EMOJI: $EMOJI"
  echo -e "USE_BEDROCK: $USE_BEDROCK"
  if [ "$USE_BEDROCK" = "true" ]; then
    echo -e "BEDROCK_MODEL: $BEDROCK_MODEL"
  fi
fi

# Check if both emoji and message are provided
if [ "$GENERATE" = true ] && [ -z "$DIFF_CONTENT" ] && [ -z "$DIFF_FILE" ] && [ -z "$MESSAGE" ]; then
  echo "At least one of the following options is required: -d, -f, -m"
  display_help
  exit 1
fi

# Check if both emoji and message are provided
if [ "$ASSESS" = true ] && [ -z "$DIFF_CONTENT" ] && [ -z "$DIFF_FILE" ]; then
  echo "At least one of the following options is required: -d, -f for assessment"
  display_help
  exit 1
fi

get_diff_content() {
  if [ "$VERBOSE" = true ]; then
    echo -e "get_diff_content"
  fi

  #read diff from file
  if [ ! "$DIFF_CONTENT" ] && [ "$DIFF_FILE" ]; then
    if [ ! -f "$DIFF_FILE" ]; then
      echo "no such file $DIFF_FILE"
      exit 1
    fi
    DIFF_CONTENT=$(cat $DIFF_FILE)
  fi

  # Check the size of DIFF_CONTENT
  if [ ${#DIFF_CONTENT} -gt 100000 ]; then
    echo "Error: The diff is too large. Maximum allowed is 100000 characters. (30000 tokens)"
    exit 1
  fi
}

# Function to sign AWS requests for Bedrock API
aws_signed_request() {
  local data=$1
  local response
  local encoded_data
  
  # Base64 encode the JSON data
  encoded_data=$(echo -n "$data" | base64 -w 0)
  
  # Use AWS CLI to call Bedrock
  response=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
             AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
             aws bedrock-runtime invoke-model \
             --region $AWS_REGION \
             --model-id $BEDROCK_MODEL \
             --content-type "application/json" \
             --body "$encoded_data" \
             /dev/stdout 2>&1)
  
  # Check if there was an AWS CLI error
  local aws_exit_code=$?
  if [ $aws_exit_code -ne 0 ]; then
    echo -e "AWS CLI ERROR: aws bedrock-runtime invoke-model failed with exit code $aws_exit_code"
    echo -e "ERROR DETAILS: $response"
    if [ "$VERBOSE" = true ]; then
      echo -e "JSON sent to AWS Bedrock:"
      echo "$data" | jq '.'
    fi
    exit 1
  fi

  local result=$(echo $response | jq -r .content[0].text)
  echo "$result"  # Return the result
}

check_for_errors() {
  local response=$1
  if [ "$USE_BEDROCK" = "true" ]; then

 
    # For debugging, if verbose mode is on, show the full structure
    if [ "$VERBOSE" = true ]; then
      echo "$response" 
    fi
  else
    # Check for OpenAI API errors
    ERROR=$(echo $response | jq -r '.error.message')
    if [ "$ERROR" == 'null' ]; then
      return
    fi
    if [ "$ERROR" ]; then
      echo -e "ERROR: $ERROR"
      echo -e "RESPONSE: $response"
      exit 1
    fi
  fi
}

# Helper function to extract content from Bedrock Claude responses
extract_bedrock_content() {
  local response=$1
  # Try multiple possible response formats for different Claude models/versions
  local content=$(echo "$response" | jq -r '.completion // .content[0].text // .results[0].outputText // ""')
  
  # Claude 3 Sonnet Bedrock specific format (messages array)
  if [[ -z "$content" || "$content" == "null" ]]; then
    content=$(echo "$response" | jq -r '.messages[-1].content[0].text // ""')
  fi
  
  echo "$content"
}

generate_message() {
  if [ "$VERBOSE" = true ]; then
    echo -e "generate_message *******************************************************************"
  fi

  get_diff_content

  # Prepare the data for the API call
  SYSTEM_PROMPT="You are a system that generates git commit messages from diff.
  You will be given a diff and your task is to generate a git commit message.
  You will provide only one commit message for each diff.
  Your answer should contain only single commit message, nothing else.
  Use english language only.
  Use multiple lines for the response.
  Try to use maximum 100 words in the response.
  "

  PREFIX_RX="\"" 

  if [ "$USE_BEDROCK" = "true" ]; then
    # Prepare data for Bedrock Claude API using jq to properly escape values
    # Note: Claude on Bedrock does not support system messages
    # We'll prepend the system prompt to the user text as a workaround
    combined_text="$SYSTEM_PROMPT

$MESSAGE"
    
    DATA=$(jq -n \
           --arg version "bedrock-2023-05-31" \
           --arg text "$combined_text" \
           '{
             anthropic_version: $version,
             max_tokens: 500,
             messages: [
               {
                 role: "user",
                 content: [
                   {
                     type: "text",
                     text: $text
                   }
                 ]
               }
             ]
           }')
    
    if [ "$VERBOSE" = true ]; then
      echo -e "Bedrock model being used: $BEDROCK_MODEL"
      echo -e "Request data structure:"
      echo "$DATA" | jq '.'
    fi
    
    # Make the API call to AWS Bedrock
    RESPONSE=$(aws_signed_request "$DATA")
    
    check_for_errors "$RESPONSE"
    
    # Extract and display the answer from Claude response
    if [ "$VERBOSE" = true ]; then
      echo -e "Extracting message from Bedrock response..."
      echo -e "Response structure: $(echo $RESPONSE | jq -r 'keys')"
    fi
    
    # Use the helper function to extract content
    GPT_MESSAGE=$(extract_bedrock_content "$RESPONSE")
    
    if [ "$VERBOSE" = true ]; then
      echo -e "Extracted message: $GPT_MESSAGE"
      if [ -z "$GPT_MESSAGE" ]; then
        echo -e "WARNING: Failed to extract message from response. Full response:"
        echo "$RESPONSE" | jq '.'
      fi
    fi
  else
    # Original OpenAI API call
    JSON='{
      "model": $api_model,
      "messages": [
        {
          "role": "system",
          "content": $system_prompt
        },
        {
          "role": "user",
          "content": $prompt
        }
      ],
      "max_tokens": 200,
      "temperature": 0.999,
      "top_p": 1,
      "frequency_penalty": 0.0,
      "presence_penalty": 0.0
    }'

    DATA=$(jq -n --arg system_prompt "$SYSTEM_PROMPT" --arg prompt "$DIFF_CONTENT" --arg api_model "$API_MODEL" "$JSON")

    # Make the API call to OpenAI
    RESPONSE=$(curl -s \
                    -X POST "$API_BASE_URL/chat/completions" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $API_KEY" \
                    -d "$DATA")

    check_for_errors "$RESPONSE"

    # Extract and display the answer
    GPT_MESSAGE=$(echo $RESPONSE | jq -r '.choices[0].message.content' | sed 's/^"//;s/"$//')
  fi
  
  if [ -z "$MESSAGE" ]; then
    MESSAGE=$(echo -e "${GPT_MESSAGE}")
  else
    MESSAGE=$(echo -e "${MESSAGE}""${GPT_MESSAGE}")
  fi
  RESULT=$(echo -e "${MESSAGE}")
}

assess_diff() {
  if [ "$VERBOSE" = true ]; then
    echo -e "assess_diff *******************************************************************"
  fi

  get_diff_content

  # Prepare the data for the API call
  SYSTEM_PROMPT="You are a system that evaluate code quality and assesses the git diff.
  You will be given a diff and your task is to assess this diff.
  Analyze code changes in the diff and provide a detailed evaluation of the changes.
  You will provide only one assessment for each diff.
  Based on the provided git diff evaluate the code changes on several factors: code cleanliness, structure, readability, complexity, and overall code quality.
  Use english language for the response only.
  Use multiple lines for the response.
  Try to use maximum 250 words in the response.
  Add the final rating on the scale from 1 to 10 at the end of the response.
  "

  if [ "$RATING" = true ]; then
    RATING_PROMPT="
    Your answer should contain only the rating (10 emoji) and nothing else.
    "
    SYSTEM_PROMPT=$(echo -e "${SYSTEM_PROMPT}""${RATING_PROMPT}")
  elif [ "$MARKDOWN" = true ]; then
    RATING_PROMPT="
    Provide all the answer in Markdown format.
    "
    SYSTEM_PROMPT=$(echo -e "${SYSTEM_PROMPT}""${RATING_PROMPT}")
  else
    RATING_PROMPT="
    Provide the answer in plain text format no additional formatting required. Do not use any Markdown formatting.
    "
    SYSTEM_PROMPT=$(echo -e "${SYSTEM_PROMPT}""${RATING_PROMPT}")
  fi

  if [ "$USE_BEDROCK" = "true" ]; then
    # Prepare data for Bedrock Claude API using jq to properly escape values
    # Note: Claude on Bedrock does not support system messages
    # We'll prepend the system prompt to the user text as a workaround
    combined_text="$SYSTEM_PROMPT

$DIFF_CONTENT"
    
    DATA=$(jq -n \
           --arg version "bedrock-2023-05-31" \
           --arg text "$combined_text" \
           '{
             anthropic_version: $version,
             max_tokens: 500,
             messages: [
               {
                 role: "user",
                 content: [
                   {
                     type: "text",
                     text: $text
                   }
                 ]
               }
             ]
           }')
    
    if [ "$VERBOSE" = true ]; then
      echo -e "Bedrock model being used: $BEDROCK_MODEL"
      echo -e "Request data structure:"
      echo "$DATA" | jq '.'
    fi
    
    # Make the API call to AWS Bedrock
    RESPONSE=$(aws_signed_request "$DATA")
    RESULT="$RESPONSE"  # Store the response in RESULT

  fi

}


if  [ "$GENERATE" = true ] && ([ "$DIFF_CONTENT" ] || [ "$DIFF_FILE" ]); then
  generate_message
fi

if [ "$EMOJI" = true ]; then
  generate_emoji
fi

if [ "$ASSESS" = true ]; then
  assess_diff
fi
echo -e "${RESULT}"
exit 0

