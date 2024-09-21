#!/usr/bin/env bash

# Check layer3 availability
# Used for GRE / VPN tunnel availability checks

# (C) 2024 NetInvent SAS under BSD-3-Clause license
SCRIPT_BUILD=2024092101

# Default values that can be overrided via a file
CONF_FILE=/etc/hosts_up.conf
LOG_FILE=/var/log/hosts_up.log
NODE_EXPORTER_TEXT_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="hosts_up.prom"


## OFUNCTIONS 2.4.8 imports
# Sub function of Logger
_Logger() {
        local logValue="${1}"           # Log to file
        local stdValue="${2}"           # Log to screeen
        local toStdErr="${3:-false}"    # Log to stderr instead of stdout

        if [ "$logValue" != "" ] && [ "$LOG_FILE" != "" ]; then
                echo -e "$logValue" >> "$LOG_FILE"
        fi

        if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
                if [ $toStdErr == true ]; then
                        # Force stderr color in subshell
                        (>&2 echo -e "$stdValue")

                else
                        echo -e "$stdValue"
                fi
        fi
}

Logger() {
        local value="${1}"              # Sentence to log (in double quotes)
        local level="${2}"              # Log level
        local retval="${3:-undef}"      # optional return value of command

        local prefix

        if [ "$_LOGGER_PREFIX" == "time" ]; then
                prefix="TIME: $SECONDS - "
        elif [ "$_LOGGER_PREFIX" == "date" ]; then
                prefix="$(date '+%Y-%m-%d %H:%M:%S') - "
        else
                prefix=""
        fi

        if [ "$level" == "CRITICAL" ]; then
                _Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
                return
        elif [ "$level" == "ERROR" ]; then
                _Logger "$prefix($level):$value" "$prefix\e[91m$value\e[0m" true
                return
        elif [ "$level" == "WARN" ]; then
                _Logger "$prefix($level):$value" "$prefix\e[33m$value\e[0m" true
                return
        elif [ "$level" == "NOTICE" ]; then
                if [ "$_LOGGER_ERR_ONLY" != true ]; then
                        _Logger "$prefix$value" "$prefix$value"
                fi
                return
        elif [ "$level" == "VERBOSE" ]; then
                if [ "$_LOGGER_VERBOSE" == true ]; then
                        _Logger "$prefix($level):$value" "$prefix$value"
                fi
                return
        elif [ "$level" == "ALWAYS" ]; then
                _Logger "$prefix$value" "$prefix$value"
                return
        elif [ "$level" == "DEBUG" ]; then
                if [ "$_DEBUG" == true ]; then
                        _Logger "$prefix$value" "$prefix$value"
                        return
                fi
        elif [ "$level" == "PARANOIA_DEBUG" ]; then                             #__WITH_PARANOIA_DEBUG
                if [ "$_PARANOIA_DEBUG" == true ]; then                 #__WITH_PARANOIA_DEBUG
                        _Logger "$prefix$value" "$prefix\e[35m$value\e[0m"      #__WITH_PARANOIA_DEBUG
                        return                                                  #__WITH_PARANOIA_DEBUG
                fi                                                              #__WITH_PARANOIA_DEBUG
        else
                _Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
                _Logger "Value was: $prefix$value" "Value was: $prefix$value" true
        fi
}

_OFUNCTIONS_SPINNER="|/-\\"
Spinner() {
        if [ "$_LOGGER_SILENT" == true ] || [ "$_LOGGER_ERR_ONLY" == true ]; then
                return 0
        else
                printf " [%c]  \b\b\b\b\b\b" "$_OFUNCTIONS_SPINNER"
                _OFUNCTIONS_SPINNER=${_OFUNCTIONS_SPINNER#?}${_OFUNCTIONS_SPINNER%%???}
                return 0
        fi
}

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
joinString() {
        local IFS="$1"; shift; echo "$*";
}

## Modified version of http://stackoverflow.com/a/8574392
## Usage: [ $(ArrayContains "needle" "${haystack[@]}") -eq 1 ]
ArrayContains() {
        local needle="${1}"
        local haystack="${2}"
        local e

        if [ "$needle" != "" ] && [ "$haystack" != "" ]; then
                for e in "${@:2}"; do
                        if [ "$e" == "$needle" ]; then
                                echo 1
                                return
                        fi
                done
        fi
        echo 0
        return
}

# Function is busybox compatible since busybox ash does not understand direct regex, we use expr
IsInteger() {
        local value="${1}"

        if type expr > /dev/null 2>&1; then
                expr "$value" : '^[0-9]\{1,\}$' > /dev/null 2>&1
                if [ $? -eq 0 ]; then
                        echo 1
                else
                        echo 0
                fi
        else
                if [[ $value =~ ^[0-9]+$ ]]; then
                        echo 1
                else
                        echo 0
                fi
        fi
}

## Full call
##ExecTasks "$mainInput" "$id" $readFromFile $softPerProcessTime $hardPerProcessTime $softMaxTime $hardMaxTime $counting $sleepTime $keepLogging $spinner $noTimeErrorLog $noErrorLogsAtAll $numberOfProcesses $auxInput $maxPostponeRetries $minTimeBetweenRetries $validExitCodes

ExecTasks() {
        # Mandatory arguments
        local mainInput="${1}"                          # Contains list of pids / commands separated by semicolons or filepath to list of pids / commands

        # Optional arguments
        local id="${2:-(undisclosed)}"                  # Optional ID in order to identify global variables from this run (only bash variable names, no '-'). Global variables are WAIT_FOR_TASK_COMPLETION_$id and HARD_MAX_EXEC_TIME_REACHED_$id
        local readFromFile="${3:-false}"                # Is mainInput / auxInput a semicolon separated list (true) or a filepath (false)
        local softPerProcessTime="${4:-0}"              # Max time (in seconds) a pid or command can run before a warning is logged, unless set to 0
        local hardPerProcessTime="${5:-0}"              # Max time (in seconds) a pid or command can run before the given command / pid is stopped, unless set to 0
        local softMaxTime="${6:-0}"                     # Max time (in seconds) for the whole function to run before a warning is logged, unless set to 0
        local hardMaxTime="${7:-0}"                     # Max time (in seconds) for the whole function to run before all pids / commands given are stopped, unless set to 0
        local counting="${8:-true}"                     # Should softMaxTime and hardMaxTime be accounted since function begin (true) or since script begin (false)
        local sleepTime="${9:-.5}"                      # Seconds between each state check. The shorter the value, the snappier ExecTasks will be, but as a tradeoff, more cpu power will be used (good values are between .05 and 1)
        local keepLogging="${10:-1800}"                 # Every keepLogging seconds, an alive message is logged. Setting this value to zero disables any alive logging
        local spinner="${11:-true}"                     # Show spinner (true) or do not show anything (false) while running
        local noTimeErrorLog="${12:-false}"             # Log errors when reaching soft / hard execution times (false) or do not log errors on those triggers (true)
        local noErrorLogsAtAll="${13:-false}"           # Do not log any errros at all (useful for recursive ExecTasks checks)

        # Parallelism specific arguments
        local numberOfProcesses="${14:-0}"              # Number of simulanteous commands to run, given as mainInput. Set to 0 by default (WaitForTaskCompletion mode). Setting this value enables ParallelExec mode.
        local auxInput="${15}"                          # Contains list of commands separated by semicolons or filepath fo list of commands. Exit code of those commands decide whether main commands will be executed or not
        local maxPostponeRetries="${16:-3}"             # If a conditional command fails, how many times shall we try to postpone the associated main command. Set this to 0 to disable postponing
        local minTimeBetweenRetries="${17:-300}"        # Time (in seconds) between postponed command retries
        local validExitCodes="${18:-0}"                 # Semi colon separated list of valid main command exit codes which will not trigger errors

        local i

        Logger "${FUNCNAME[0]} id [$id] called by [${FUNCNAME[1]} < ${FUNCNAME[2]} < ${FUNCNAME[3]} < ${FUNCNAME[4]} < ${FUNCNAME[5]} < ${FUNCNAME[6]} ...]." "PARANOIA_DEBUG"  #__WITH_PARANOIA_DEBUG

        # Since ExecTasks takes up to 17 arguments, do a quick preflight check in DEBUG mode
        if [ "$_DEBUG" == true ]; then
                declare -a booleans=(readFromFile counting spinner noTimeErrorLog noErrorLogsAtAll)
                for i in "${booleans[@]}"; do
                        test="if [ \$$i != false ] && [ \$$i != true ]; then Logger \"Bogus $i value [\$$i] given to ${FUNCNAME[0]}.\" \"CRITICAL\"; exit 1; fi"
                        eval "$test"
                done
                declare -a integers=(softPerProcessTime hardPerProcessTime softMaxTime hardMaxTime keepLogging numberOfProcesses maxPostponeRetries minTimeBetweenRetries)
                for i in "${integers[@]}"; do
                        test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] given to ${FUNCNAME[0]}.\" \"CRITICAL\"; exit 1; fi"
                        eval "$test"
                done
        fi

        # Expand validExitCodes into array
        IFS=';' read -r -a validExitCodes <<< "$validExitCodes"

        # ParallelExec specific variables
        local auxItemCount=0            # Number of conditional commands
        local commandsArray=()          # Array containing commands
        local commandsConditionArray=() # Array containing conditional commands
        local currentCommand            # Variable containing currently processed command
        local currentCommandCondition   # Variable containing currently processed conditional command
        local commandsArrayPid=()       # Array containing commands indexed by pids
        local commandsArrayOutput=()    # Array containing command results indexed by pids
        local postponedRetryCount=0     # Number of current postponed commands retries
        local postponedItemCount=0      # Number of commands that have been postponed (keep at least one in order to check once)
        local postponedCounter=0
        local isPostponedCommand=false  # Is the current command from a postponed file ?
        local postponedExecTime=0       # How much time has passed since last postponed condition was checked
        local needsPostponing           # Does currentCommand need to be postponed
        local temp

        # Common variables
        local pid                       # Current pid working on
        local pidState                  # State of the process
        local mainItemCount=0           # number of given items (pids or commands)
        local readFromFile              # Should we read pids / commands from a file (true)
        local counter=0
        local log_ttime=0               # local time instance for comparaison

        local seconds_begin=$SECONDS    # Seconds since the beginning of the script
        local exec_time=0               # Seconds since the beginning of this function

        local retval=0                  # return value of monitored pid process
        local subRetval=0               # return value of condition commands
        local errorcount=0              # Number of pids that finished with errors
        local pidsArray                 # Array of currently running pids
        local newPidsArray              # New array of currently running pids for next iteration
        local pidsTimeArray             # Array containing execution begin time of pids
        local executeCommand            # Boolean to check if currentCommand can be executed given a condition
        local hasPids=false             # Are any valable pids given to function ?              #__WITH_PARANOIA_DEBUG
        local functionMode
        local softAlert=false           # Does a soft alert need to be triggered, if yes, send an alert once
        local failedPidsList            # List containing failed pids with exit code separated by semicolons (eg : 2355:1;4534:2;2354:3)
        local randomOutputName          # Random filename for command outputs
        local currentRunningPids        # String of pids running, used for debugging purposes only

        # Init function variables depending on mode

        if [ $numberOfProcesses -gt 0 ]; then
                functionMode=ParallelExec
        else
                functionMode=WaitForTaskCompletion
        fi

        if [ $readFromFile == false ]; then
                if [ $functionMode == "WaitForTaskCompletion" ]; then
                        IFS=';' read -r -a pidsArray <<< "$mainInput"
                        mainItemCount="${#pidsArray[@]}"
                else
                        IFS=';' read -r -a commandsArray <<< "$mainInput"
                        mainItemCount="${#commandsArray[@]}"
                        IFS=';' read -r -a commandsConditionArray <<< "$auxInput"
                        auxItemCount="${#commandsConditionArray[@]}"
                fi
        else
                if [ -f "$mainInput" ]; then
                        mainItemCount=$(wc -l < "$mainInput")
                        readFromFile=true
                else
                        Logger "Cannot read main file [$mainInput]." "WARN"
                fi
                if [ "$auxInput" != "" ]; then
                        if [ -f "$auxInput" ]; then
                                auxItemCount=$(wc -l < "$auxInput")
                        else
                                Logger "Cannot read aux file [$auxInput]." "WARN"
                        fi
                fi
        fi

        if [ $functionMode == "WaitForTaskCompletion" ]; then
                # Force first while loop condition to be true because we do not deal with counters but pids in WaitForTaskCompletion mode
                counter=$mainItemCount
        fi

        Logger "Running ${FUNCNAME[0]} as [$functionMode] for [$mainItemCount] mainItems and [$auxItemCount] auxItems." "PARANOIA_DEBUG"              #__WITH_PARANOIA_DEBUG

        # soft / hard execution time checks that needs to be a subfunction since it is called both from main loop and from parallelExec sub loop
        function _ExecTasksTimeCheck {
                if [ $spinner == true ] && [ "$_OFUNCTIONS_SHOW_SPINNER" != false ]; then
                        Spinner
                fi
                if [ $counting == true ]; then
                        exec_time=$((SECONDS - seconds_begin))
                else
                        exec_time=$SECONDS
                fi

                if [ $keepLogging -ne 0 ]; then
                        # This log solely exists for readability purposes before having next set of logs
                        if [ ${#pidsArray[@]} -eq $numberOfProcesses ] && [ $log_ttime -eq 0 ]; then
                                log_ttime=$exec_time
                                Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue of which $postponedItemCount are postponed. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
                        fi
                        if [ $(((exec_time + 1) % keepLogging)) -eq 0 ]; then
                                if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1 second
                                        log_ttime=$exec_time
                                        if [ $functionMode == "WaitForTaskCompletion" ]; then
                                                Logger "Current tasks ID=$id still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
                                        elif [ $functionMode == "ParallelExec" ]; then
                                                Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue of which $postponedItemCount are postponed. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
                                        fi
                                fi
                        fi
                fi

                if [ $exec_time -gt $softMaxTime ]; then
                        if [ "$softAlert" != true ] && [ $softMaxTime -ne 0 ] && [ $noTimeErrorLog != true ]; then
                                Logger "Max soft execution time [$softMaxTime] exceeded for task [$id] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
                                softAlert=true
                                SendAlert true
                        fi
                fi

                if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
                        if [ $noTimeErrorLog != true ]; then
                                Logger "Max hard execution time [$hardMaxTime] exceeded for task [$id] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
                        fi
                        for pid in "${pidsArray[@]}"; do
                                KillChilds $pid true
                                if [ $? -eq 0 ]; then
                                        Logger "Task with pid [$pid] stopped successfully." "NOTICE"
                                else
                                        if [ $noErrorLogsAtAll != true ]; then
                                                Logger "Could not stop task with pid [$pid]." "ERROR"
                                        fi
                                fi
                                errorcount=$((errorcount+1))
                        done
                        if [ $noTimeErrorLog != true ]; then
                                SendAlert true
                        fi
                        eval "HARD_MAX_EXEC_TIME_REACHED_$id=true"
                        if [ $functionMode == "WaitForTaskCompletion" ]; then
                                return $errorcount
                        else
                                return 129
                        fi
                fi
        }

        function _ExecTasksPidsCheck {
                newPidsArray=()

                if [ "$currentRunningPids" != "$(joinString " " ${pidsArray[@]})" ]; then
                        Logger "ExecTask running for pids [$(joinString " " ${pidsArray[@]})]." "DEBUG"
                        currentRunningPids="$(joinString " " ${pidsArray[@]})"
                fi

                for pid in "${pidsArray[@]}"; do
                        if [ $(IsInteger $pid) -eq 1 ]; then
                                if kill -0 $pid > /dev/null 2>&1; then
                                        # Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
                                        pidState="$(eval $PROCESS_STATE_CMD)"
                                        if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then

                                                # Check if pid has not run more than soft/hard perProcessTime
                                                pidsTimeArray[$pid]=$((SECONDS - seconds_begin))
                                                if [ ${pidsTimeArray[$pid]} -gt $softPerProcessTime ]; then
                                                        if [ "$softAlert" != true ] && [ $softPerProcessTime -ne 0 ] && [ $noTimeErrorLog != true ]; then
                                                                Logger "Max soft execution time [$softPerProcessTime] exceeded for pid [$pid]." "WARN"
                                                                if [ "${commandsArrayPid[$pid]}]" != "" ]; then
                                                                        Logger "Command was [${commandsArrayPid[$pid]}]]." "WARN"
                                                                fi
                                                                softAlert=true
                                                                SendAlert true
                                                        fi
                                                fi


                                                if [ ${pidsTimeArray[$pid]} -gt $hardPerProcessTime ] && [ $hardPerProcessTime -ne 0 ]; then
                                                        if [ $noTimeErrorLog != true ] && [ $noErrorLogsAtAll != true ]; then
                                                                Logger "Max hard execution time [$hardPerProcessTime] exceeded for pid [$pid]. Stopping command execution." "ERROR"
                                                                if [ "${commandsArrayPid[$pid]}]" != "" ]; then
                                                                        Logger "Command was [${commandsArrayPid[$pid]}]]." "WARN"
                                                                fi
                                                        fi
                                                        KillChilds $pid true
                                                        if [ $? -eq 0 ]; then
                                                                 Logger "Command with pid [$pid] stopped successfully." "NOTICE"
                                                        else
                                                                if [ $noErrorLogsAtAll != true ]; then
                                                                Logger "Could not stop command with pid [$pid]." "ERROR"
                                                                fi
                                                        fi
                                                        errorcount=$((errorcount+1))

                                                        if [ $noTimeErrorLog != true ]; then
                                                                SendAlert true
                                                        fi
                                                fi

                                                newPidsArray+=($pid)
                                        fi
                                else
                                        # pid is dead, get its exit code from wait command
                                        wait $pid
                                        retval=$?
                                        # Check for valid exit codes
                                        if [ $(ArrayContains $retval "${validExitCodes[@]}") -eq 0 ]; then
                                                if [ "$noErrorLogsAtAll" != true ]; then
                                                        Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "ERROR"
                                                        if [ "$functionMode" == "ParallelExec" ]; then
                                                                Logger "Command was [${commandsArrayPid[$pid]}]." "ERROR"
                                                        fi
                                                        if [ -f "${commandsArrayOutput[$pid]}" ]; then
                                                                Logger "Truncated output:\n$(head -c16384 "${commandsArrayOutput[$pid]}")" "ERROR"
                                                        fi
                                                fi
                                                errorcount=$((errorcount+1))
                                                # Welcome to variable variable bash hell
                                                if [ "$failedPidsList" == "" ]; then
                                                        failedPidsList="$pid:$retval"
                                                else
                                                        failedPidsList="$failedPidsList;$pid:$retval"
                                                fi
                                        elif [ "$_DEBUG" == true ]; then
                                                if [ -f "${commandsArrayOutput[$pid]}" ]; then
                                                        Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "DEBUG"
                                                        Logger "Truncated output:\n$(head -c16384 "${commandsArrayOutput[$pid]}")" "DEBUG"
                                                fi
                                        else
                                                Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "DEBUG"
                                        fi
                                fi
                                hasPids=true                                    ##__WITH_PARANOIA_DEBUG
                        fi
                done

                # hasPids can be false on last iteration in ParallelExec mode
                if [ $hasPids == false ] && [ "$functionMode" = "WaitForTaskCompletion" ]; then                                 ##__WITH_PARANOIA_DEBUG
                        Logger "No valable pids given." "ERROR"                                                                 ##__WITH_PARANOIA_DEBUG
                fi                                                                                                              ##__WITH_PARANOIA_DEBUG
                pidsArray=("${newPidsArray[@]}")

                # Trivial wait time for bash to not eat up all CPU
                sleep $sleepTime

                if [ "$_PERF_PROFILER" == true ]; then                          ##__WITH_PARANOIA_DEBUG
                        _PerfProfiler                                           ##__WITH_PARANOIA_DEBUG
                fi                                                              ##__WITH_PARANOIA_DEBUG

        }

        while [ ${#pidsArray[@]} -gt 0 ] || [ $counter -lt $mainItemCount ] || [ $postponedItemCount -ne 0 ]; do
                _ExecTasksTimeCheck
                retval=$?
                if [ $retval -ne 0 ]; then
                        return $retval;
                fi

                # The following execution bloc is only needed in ParallelExec mode since WaitForTaskCompletion does not execute commands, but only monitors them
                if [ $functionMode == "ParallelExec" ]; then
                        while [ ${#pidsArray[@]} -lt $numberOfProcesses ] && ([ $counter -lt $mainItemCount ] || [ $postponedItemCount -ne 0 ]); do
                                _ExecTasksTimeCheck
                                retval=$?
                                if [ $retval -ne 0 ]; then
                                        return $retval;
                                fi

                                executeCommand=false
                                isPostponedCommand=false
                                currentCommand=""
                                currentCommandCondition=""
                                needsPostponing=false

                                if [ $readFromFile == true ]; then
                                        # awk identifies first line as 1 instead of 0 so we need to increase counter
                                        currentCommand=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$mainInput")
                                        if [ $auxItemCount -ne 0 ]; then
                                                currentCommandCondition=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$auxInput")
                                        fi

                                        # Check if we need to fetch postponed commands
                                        if [ "$currentCommand" == "" ]; then
                                                currentCommand=$(awk 'NR == num_line {print; exit}' num_line=$((postponedCounter+1)) "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedMain.$id.$SCRIPT_PID.$TSTAMP")
                                                currentCommandCondition=$(awk 'NR == num_line {print; exit}' num_line=$((postponedCounter+1)) "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedAux.$id.$SCRIPT_PID.$TSTAMP")
                                                isPostponedCommand=true
                                        fi
                                else
                                        currentCommand="${commandsArray[$counter]}"
                                        if [ $auxItemCount -ne 0 ]; then
                                                currentCommandCondition="${commandsConditionArray[$counter]}"
                                        fi

                                        if [ "$currentCommand" == "" ]; then
                                                currentCommand="${postponedCommandsArray[$postponedCounter]}"
                                                currentCommandCondition="${postponedCommandsConditionArray[$postponedCounter]}"
                                                isPostponedCommand=true
                                        fi
                                fi

                                # Check if we execute postponed commands, or if we delay them
                                if [ $isPostponedCommand == true ]; then
                                        # Get first value before '@'
                                        postponedExecTime="${currentCommand%%@*}"
                                        postponedExecTime=$((SECONDS-postponedExecTime))
                                        # Get everything after first '@'
                                        temp="${currentCommand#*@}"
                                        # Get first value before '@'
                                        postponedRetryCount="${temp%%@*}"
                                        # Replace currentCommand with actual filtered currentCommand
                                        currentCommand="${temp#*@}"

                                        # Since we read a postponed command, we may decrase postponedItemCounter
                                        postponedItemCount=$((postponedItemCount-1))
                                        #Since we read one line, we need to increase the counter
                                        postponedCounter=$((postponedCounter+1))

                                else
                                        postponedRetryCount=0
                                        postponedExecTime=0
                                fi
                                if ([ $postponedRetryCount -lt $maxPostponeRetries ] && [ $postponedExecTime -ge $minTimeBetweenRetries ]) || [ $isPostponedCommand == false ]; then
                                        if [ "$currentCommandCondition" != "" ]; then
                                                Logger "Checking condition [$currentCommandCondition] for command [$currentCommand]." "DEBUG"
                                                eval "$currentCommandCondition" &
                                                ExecTasks $! "subConditionCheck" false 0 0 1800 3600 true $SLEEP_TIME $KEEP_LOGGING true true true
                                                subRetval=$?
                                                if [ $subRetval -ne 0 ]; then
                                                        # is postponing enabled ?
                                                        if [ $maxPostponeRetries -gt 0 ]; then
                                                                Logger "Condition [$currentCommandCondition] not met for command [$currentCommand]. Exit code [$subRetval]. Postponing command." "NOTICE"
                                                                postponedRetryCount=$((postponedRetryCount+1))
                                                                if [ $postponedRetryCount -ge $maxPostponeRetries ]; then
                                                                        Logger "Max retries reached for postponed command [$currentCommand]. Skipping command." "NOTICE"
                                                                else
                                                                        needsPostponing=true
                                                                fi
                                                                postponedExecTime=0
                                                        else
                                                                Logger "Condition [$currentCommandCondition] not met for command [$currentCommand]. Exit code [$subRetval]. Ignoring command." "NOTICE"
                                                        fi
                                                else
                                                        executeCommand=true
                                                fi
                                        else
                                                executeCommand=true
                                        fi
                                else
                                        needsPostponing=true
                                fi

                                if [ $needsPostponing == true ]; then
                                        postponedItemCount=$((postponedItemCount+1))
                                        if [ $readFromFile == true ]; then
                                                echo "$((SECONDS-postponedExecTime))@$postponedRetryCount@$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedMain.$id.$SCRIPT_PID.$TSTAMP"
                                                echo "$currentCommandCondition" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedAux.$id.$SCRIPT_PID.$TSTAMP"
                                        else
                                                postponedCommandsArray+=("$((SECONDS-postponedExecTime))@$postponedRetryCount@$currentCommand")
                                                postponedCommandsConditionArray+=("$currentCommandCondition")
                                        fi
                                fi

                                if [ $executeCommand == true ]; then
                                        Logger "Running command [$currentCommand]." "DEBUG"
                                        randomOutputName=$(date '+%Y%m%dT%H%M%S').$(PoorMansRandomGenerator 5)
                                        eval "$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$randomOutputName.$SCRIPT_PID.$TSTAMP" 2>&1 &
                                        pid=$!
                                        pidsArray+=($pid)
                                        commandsArrayPid[$pid]="$currentCommand"
                                        commandsArrayOutput[$pid]="$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$randomOutputName.$SCRIPT_PID.$TSTAMP"
                                        # Initialize pid execution time array
                                        pidsTimeArray[$pid]=0
                                else
                                        Logger "Skipping command [$currentCommand]." "DEBUG"
                                fi

                                if [ $isPostponedCommand == false ]; then
                                        counter=$((counter+1))
                                fi
                                _ExecTasksPidsCheck
                        done
                fi

        _ExecTasksPidsCheck
        done

        Logger "${FUNCNAME[0]} ended for [$id] using [$mainItemCount] subprocesses with [$errorcount] errors." "PARANOIA_DEBUG" #__WITH_PARANOIA_DEBUG

        if [ $mainItemCount -eq 1 ]; then
                return $retval
        else
                return $errorcount
        fi
}
## OFUNCTIONS 2.4.8 import end

_host_ping() {
        local host="${1}"

        Logger "Running ping for host ${host}" "NOTICE"
        ping -i ${PING_INTERVAL} -c ${PING_RETRIES} -W ${PING_TIMEOUT} ${host} > /dev/null 2>&1
        printf "ping_up{target_host=\""${host}"\""${LABEL}"} "$?"\n" >> "${NODE_EXPORTER_TEXT_COLLECTOR_DIR}/${PROM_FILE}"
        return
}

host_ping() {
        Logger "Running hosts_up script on $(hostname)" "NOTICE"
        printf "# TYPE ping_up gauge\n# HELP layer3_up Is some IP reachable from our host\n" > "${NODE_EXPORTER_TEXT_COLLECTOR_DIR}/${PROM_FILE}"

        LABEL=""
        if [ "${OPTIONAL_PROMETHEUS_TYPE_LABEL}" != "" ]; then
                LABEL=",type=\""${OPTIONAL_PROMETHEUS_TYPE_LABEL}"\""
        fi

        pids=""
        for host in ${ping_hosts[@]}; do
                _host_ping "$host" &
                pids="$pids;$!"
        done
        ExecTasks $pids
        exit 0
}

TrapError() {
        local job="$0"
        local line="$1"
        local code="${2:-1}"

        if [ $_LOGGER_SILENT == false ]; then
                (>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
        fi
}

function TrapQuit {
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
                Logger "Finished succesfully" "NOTICE"
        else
                Logger "Finished with exit code $?" "ERROR"
        fi
        exit $exit_code
}

trap 'TrapError ${LINENO} $?' ERR
trap TrapQuit TERM EXIT HUP QUIT

for arg in "${@}"; do
        case "$arg" in
                --version)
                echo "${0} ${SCRIPT_BUILD}"
                exit 0
                ;;
                --config=*)
                CONF_FILE="${arg##*=}"
                break
                ;;
        esac
done

[ -f "${CONF_FILE}" ] || (echo "Configuration file ${CONF_FILE} not found."; exit 1)
source "${CONF_FILE}"
[ ! -d "${NODE_EXPORTER_TEXT_COLLECTOR_DIR}" ] && mkdir -p "${NODE_EXPORTER_TEXT_COLLECTOR_DIR}"
host_ping
