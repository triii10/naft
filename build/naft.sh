#!/bin/bash

# @describe (Not-Another-Fing-Tool) CLI to automate benchmarking a VM with fio and capturing perf trace

# @meta version 0.0.1
# @meta author Trilok Bhattacharya <binary.triii@gmail.com>

spinner_wait() {

    pid=$1 # Process Id of the command to wait for
    msg=${2- Process $pid still running}
    spin="-\|/"
    local i=0
    while kill -0 $pid 2>/dev/null
    do
        local i=$(( (i+1) %4 ))
        printf "\r${spin:$i:1} $msg"
        sleep .1
    done
    printf "\n\e[A\e[K"
}

get_serverip_from_domain() {
    remote_server=$(virsh net-dhcp-leases default | grep $argc_domain | awk '{print $5}' | cut -d "/" -f 1)
}

echo_success() {
    echo $'\u2714' $1
}

echo_failure() {
    echo $'\u274c' $1
}

prerequisites() {

    # Get the Server IP of the domain
    get_serverip_from_domain

    run_timestamp=$(date +"%Y%m%d_%H%M%S")
    local folder_path="./results"
    local new_folder_path="results_${run_timestamp}"

    if [ -d "$folder_path" ]; then
        # Folder exists, move it
        tar -czf "$new_folder_path.tar.gz" "$folder_path" >/dev/null
        rm -rf $folder_path >/dev/null
    fi

    # Move the perf record output 
    if [ -f "perf.data" ]; then 
        mv "perf.data" $new_folder_path/perf.data >/dev/null
        echo_success "Existing perf.data moved to $new_folder_path/perf.data"
    fi

    if [ -d "$new_folder_path" ]; then
        echo_success "Existing folder zipped to $new_folder_path.tar.gz"
    fi

    # Perform SCP transfer
    remote_path="/tmp"
    scp "$argc_fio_ini" "$remote_server:$remote_path/$folder_path/$argc_fio_ini" >/dev/null
    
    # Check the exit status of the scp command
    if [ $? -eq 0 ]; then
        echo_success "$argc_fio_ini file transferred"
    else
        echo_failure "SCP of fio.ini failed"
        return 1
    fi

    return 0;
}

start_fio() {
    # The remote path is /tmp. Modify to change
    remote_path="/tmp/results"
    # Create a results folder 
    ssh "$remote_server" "mkdir -p $remote_path" >/dev/null

    # Execute commands over SSH
    if [ $argc_domain_password_stdin ] || [ -z $argc_domain_password ]; then
        fio_pid=$(ssh -tq "$remote_server" "sudo -S --prompt='' bash -c 'nohup fio --minimal $remote_path/$argc_fio_ini & echo \$!' >/dev/null" >/dev/null)
    else
        fio_pid=$(ssh -tq "$remote_server" "base64 -d $argc_domain_password | sudo --prompt='' -S bash -c 'nohup fio --minimal $remote_path/$argc_fio_ini & echo \$!' >/dev/null" >/dev/null)
    fi
    fio_pid=$(ssh "$remote_server" "pgrep fio -n")

    fio_clock=$(($(date +%s) + 0))
    echo '' > /tmp/fio_snap
    echo '' > /tmp/fio_snap_merge
    
    # Check the exit status of the SSH command
    if [ $? -eq 0 ]; then
        echo_success "fio started"
    else
        echo "fio could not be started"
        return 1
    fi
    return 0
}

take_single_snap() {
    local name="snap-$1"
    local present_dir=$(pwd)
    virsh snapshot-create-as --domain $argc_domain $name --diskspec vda,file=$present_dir/$name --disk-only --no-metadata >/dev/null
    
    if [ $? -eq 0 ]; then
        echo "$(($(date +%s) - $fio_clock))" >> /tmp/fio_snap
        return 0
    else
        echo_failure "Snapshot [$name] failed"
        return 1
    fi
}

take_snapshots() {
    for (( i=1; i<=$argc_snapshots; i++ )); do
        sleep $argc_period &
        spinner_wait $! "Waiting $argc_period seconds before starting snapshot $i"
        take_single_snap $i;
        if [ $? -eq 1 ]; then
            return 1
        fi
    done
    echo_success "Snapshots taken successfully"
    return 0
}

block_commit() {

    echo -n "$(($(date +%s) - $fio_clock))" >> /tmp/fio_snap_merge
    virsh blockcommit $argc_domain $argc_block_device --active --wait --delete --pivot >/dev/null
    echo -n " $(($(date +%s) - $fio_clock))" >> /tmp/fio_snap_merge

    if [ $? -eq 0 ]; then
        echo_success "Block commit successful"
        return 0
    else
        echo_failure "Block commit failed"
        return 1
    fi
}

# @cmd  Generate graphs
# @option   --python-venv!              Location to python virtual environment to generate graphs
# @option   -s --snapshots=1            Number of snapshots taken
visualize() {

    # Generate the graph

    cd results; 
    source $argc_python_venv && fio-plot -i ./ --source "https://triii.github.io/"  -T "Random read & write and block commit after $argc_snapshots snapshots" -g -t iops --xlabel-parent 0 -n 1 -d 1 -r randrw --vlines /tmp/fio_snap --vspans /tmp/fio_snap_merge --dpi 1000 -w 0.3 >/dev/null; 
    cd ..;
    echo_success "Benchmark graph generated"

}

exit_routines() {
    ssh "$remote_server" "base64 -d $argc_domain_password | sudo --prompt='' -S bash -c '$(declare -f spinner_wait); spinner_wait $fio_pid \"Waiting for fio\"'"
    # Check the exit status of the SSH command
    if [ $? -eq 0 ]; then
        echo_success "fio completed successfully"
    else
        echo_failure "fio failed"
        return 1
    fi

    # Now copy the results folder
    scp -r "$remote_server":"$remote_path/$folder_path" ./ >/dev/null
    
    # Check the exit status of the scp command
    if [ $? -eq 0 ]; then
        echo_success "Results folder copied"
    else
        echo_failure "Results folder could not be copied"
        return 1
    fi

    return 0
}

# @cmd  Run benchmarks
# @option   -s --snapshots=1            Number of snapshots to take
# @option   --period=5                  Gap between consecutive snapshots
# @option   -i --initial-wait=5         Number of seconds to wait for before starting fio
# @option   -f --fio-ini=./fio.ini      Location of the ini configuration file for fio
# @option   -b --block-commit=10        Number of seconds to wait for after last snapshot to start block commit
# @option   --block-device=vda          Block device to perform block-commit
# @option   -p --password               File containing the sudo password in base64 format
# @flag     --password-stdin            Provide sudo password in stdin
# @option   -d --domain!                Name of the VM to run benchmarks on
# @option   --domain-password           File containing the domain password in base64 format
# @flag     --domain-password-stdin     Provide domain password password in stdin
# @option   --domain-username           Username of the domain user to ssh and scp
benchmark() {

    # Execute the prerequisites
    prerequisites;
    if [ $? -eq 1 ]; then
        echo_failure "Pre-requisites failed. Exiting.."
        return 1
    fi

    start_fio;
    if [ $? -eq 1 ]; then
        echo_failure "Fio could not be started. Exiting.."
        return 1
    fi

    # Wait for some seconds specified in initial wait
    if [[ $argc_initial_wait -ne 0 ]]; then
        sleep $argc_initial_wait &
        spinner_wait $! "Waiting initially for $argc_initial_wait seconds"
    fi

    if [[ $argc_snapshots -ne 0 ]]; then
        take_snapshots;
        if [ $? -eq 1 ]; then
            echo_failure "Failure taking snapshots. Exiting.."
            return 1
        fi
    fi

    if [[ $argc_block_commit -ne 0 ]]; then
        sleep $argc_block_commit &
        spinner_wait $! "Waiting to start block commit for $argc_block_commit seconds"
        block_commit;
    fi
    
    exit_routines;
    if [ $? -eq 1 ]; then
        echo_failure "Exit routines failed. Exiting.."
        return 1
    fi
}

# @cmd  Run both benchmark and visualise commands
# @option   -s --snapshots=1            Number of snapshots to take
# @option   --period=5                  Gap between consecutive snapshots
# @option   -i --initial-wait=5         Number of seconds to wait for before starting fio
# @option   -f --fio-ini=./fio.ini      Location of the ini configuration file for fio
# @option   -b --block-commit=10        Number of seconds to wait for after last snapshot to start block commit
# @option   --block-device=vda          Block device to perform block-commit
# @option   -p --password               File containing the sudo password in base64 format
# @flag     --password-stdin            Provide sudo password in stdin
# @option   -d --domain!                Name of the VM to run benchmarks on
# @option   --domain-password           File containing the domain password in base64 format
# @flag     --domain-password-stdin     Provide domain password password in stdin
# @option   --domain-username           Username of the domain user to ssh and scp
# @option   --python-venv!              Location to python virtual environment to generate graphs
run() {
    benchmark;
    visualize;
}


# ARGC-BUILD {
# This block was generated by argc (https://github.com/sigoden/argc)
# Modifying it manually is not recommended

_argc_run() {
    if [[ "$1" == "___internal___" ]]; then
        _argc_die "error: no supported param"
    fi
    argc__args=("$(basename "$0" .sh)" "$@")
    argc__positionals=()
    _argc_index=1
    _argc_len="${#argc__args[@]}"
    _argc_tools=()
    _argc_parse
    if [ -n "$argc__fn" ]; then
        $argc__fn "${argc__positionals[@]}"
    fi
}

_argc_usage() {
    cat <<-'EOF'
naft 0.0.1
Trilok Bhattacharya <binary.triii@gmail.com>
(Not-Another-Fing-Tool) CLI to automate benchmarking a VM with fio and capturing perf trace

USAGE: naft <COMMAND>

COMMANDS:
  visualize  Generate graphs
  benchmark  Run benchmarks
  run        Run both benchmark and visualise commands
EOF
    exit
}

_argc_version() {
    echo naft 0.0.1
    exit
}

_argc_parse() {
    local _argc_key _argc_action
    local _argc_subcmds="visualize, benchmark, run"
    while [[ $_argc_index -lt $_argc_len ]]; do
        _argc_item="${argc__args[_argc_index]}"
        _argc_key="${_argc_item%%=*}"
        case "$_argc_key" in
        --help | -help | -h)
            _argc_usage
            ;;
        --version | -version | -V)
            _argc_version
            ;;
        --)
            _argc_dash="${#argc__positionals[@]}"
            argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
            _argc_index=$_argc_len
            break
            ;;
        visualize)
            _argc_index=$((_argc_index + 1))
            _argc_action=_argc_parse_visualize
            break
            ;;
        benchmark)
            _argc_index=$((_argc_index + 1))
            _argc_action=_argc_parse_benchmark
            break
            ;;
        run)
            _argc_index=$((_argc_index + 1))
            _argc_action=_argc_parse_run
            break
            ;;
        help)
            local help_arg="${argc__args[$((_argc_index + 1))]}"
            case "$help_arg" in
            visualize)
                _argc_usage_visualize
                ;;
            benchmark)
                _argc_usage_benchmark
                ;;
            run)
                _argc_usage_run
                ;;
            "")
                _argc_usage
                ;;
            *)
                _argc_die "error: invalid value \`$help_arg\` for \`<command>\`"$'\n'"  [possible values: $_argc_subcmds]"
                ;;
            esac
            ;;
        *)
            _argc_die "error: \`naft\` requires a subcommand but one was not provided"$'\n'"  [subcommands: $_argc_subcmds]"
            ;;
        esac
    done
    if [[ -n "$_argc_action" ]]; then
        $_argc_action
    else
        _argc_usage
    fi
}

_argc_usage_visualize() {
    cat <<-'EOF'
Generate graphs

USAGE: naft visualize [OPTIONS] --python-venv <PYTHON-VENV>

OPTIONS:
      --python-venv <PYTHON-VENV>  Location to python virtual environment to generate graphs
  -s, --snapshots <SNAPSHOTS>      Number of snapshots taken [default: 1]
  -h, --help                       Print help
EOF
    exit
}

_argc_parse_visualize() {
    local _argc_key _argc_action
    local _argc_subcmds=""
    while [[ $_argc_index -lt $_argc_len ]]; do
        _argc_item="${argc__args[_argc_index]}"
        _argc_key="${_argc_item%%=*}"
        case "$_argc_key" in
        --help | -help | -h)
            _argc_usage_visualize
            ;;
        --)
            _argc_dash="${#argc__positionals[@]}"
            argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
            _argc_index=$_argc_len
            break
            ;;
        --python-venv)
            _argc_take_args "--python-venv <PYTHON-VENV>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_python_venv" ]]; then
                argc_python_venv="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--python-venv\` cannot be used multiple times"
            fi
            ;;
        --snapshots | -s)
            _argc_take_args "--snapshots <SNAPSHOTS>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_snapshots" ]]; then
                argc_snapshots="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--snapshots\` cannot be used multiple times"
            fi
            ;;
        -?*)
            _argc_die "error: unexpected argument \`$_argc_key\` found"
            ;;
        *)
            argc__positionals+=("$_argc_item")
            _argc_index=$((_argc_index + 1))
            ;;
        esac
    done
    _argc_require_params "error: the following required arguments were not provided:" \
        'argc_python_venv:--python-venv <PYTHON-VENV>'
    if [[ -n "$_argc_action" ]]; then
        $_argc_action
    else
        argc__fn=visualize
        if [[ "${argc__positionals[0]}" == "help" ]] && [[ "${#argc__positionals[@]}" -eq 1 ]]; then
            _argc_usage_visualize
        fi
        if [[ -z "$argc_snapshots" ]]; then
            argc_snapshots=1
        fi
    fi
}

_argc_usage_benchmark() {
    cat <<-'EOF'
Run benchmarks

USAGE: naft benchmark [OPTIONS] --domain <DOMAIN>

OPTIONS:
  -s, --snapshots <SNAPSHOTS>              Number of snapshots to take [default: 1]
      --period <PERIOD>                    Gap between consecutive snapshots [default: 5]
  -i, --initial-wait <INITIAL-WAIT>        Number of seconds to wait for before starting fio [default: 5]
  -f, --fio-ini <FIO-INI>                  Location of the ini configuration file for fio [default: ./fio.ini]
  -b, --block-commit <BLOCK-COMMIT>        Number of seconds to wait for after last snapshot to start block commit [default: 10]
      --block-device <BLOCK-DEVICE>        Block device to perform block-commit [default: vda]
  -p, --password <PASSWORD>                File containing the sudo password in base64 format
      --password-stdin                     Provide sudo password in stdin
  -d, --domain <DOMAIN>                    Name of the VM to run benchmarks on
      --domain-password <DOMAIN-PASSWORD>  File containing the domain password in base64 format
      --domain-password-stdin              Provide domain password password in stdin
      --domain-username <DOMAIN-USERNAME>  Username of the domain user to ssh and scp
  -h, --help                               Print help
EOF
    exit
}

_argc_parse_benchmark() {
    local _argc_key _argc_action
    local _argc_subcmds=""
    while [[ $_argc_index -lt $_argc_len ]]; do
        _argc_item="${argc__args[_argc_index]}"
        _argc_key="${_argc_item%%=*}"
        case "$_argc_key" in
        --help | -help | -h)
            _argc_usage_benchmark
            ;;
        --)
            _argc_dash="${#argc__positionals[@]}"
            argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
            _argc_index=$_argc_len
            break
            ;;
        --snapshots | -s)
            _argc_take_args "--snapshots <SNAPSHOTS>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_snapshots" ]]; then
                argc_snapshots="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--snapshots\` cannot be used multiple times"
            fi
            ;;
        --period)
            _argc_take_args "--period <PERIOD>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_period" ]]; then
                argc_period="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--period\` cannot be used multiple times"
            fi
            ;;
        --initial-wait | -i)
            _argc_take_args "--initial-wait <INITIAL-WAIT>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_initial_wait" ]]; then
                argc_initial_wait="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--initial-wait\` cannot be used multiple times"
            fi
            ;;
        --fio-ini | -f)
            _argc_take_args "--fio-ini <FIO-INI>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_fio_ini" ]]; then
                argc_fio_ini="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--fio-ini\` cannot be used multiple times"
            fi
            ;;
        --block-commit | -b)
            _argc_take_args "--block-commit <BLOCK-COMMIT>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_block_commit" ]]; then
                argc_block_commit="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--block-commit\` cannot be used multiple times"
            fi
            ;;
        --block-device)
            _argc_take_args "--block-device <BLOCK-DEVICE>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_block_device" ]]; then
                argc_block_device="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--block-device\` cannot be used multiple times"
            fi
            ;;
        --password | -p)
            _argc_take_args "--password <PASSWORD>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_password" ]]; then
                argc_password="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--password\` cannot be used multiple times"
            fi
            ;;
        --password-stdin)
            if [[ "$_argc_item" == *=* ]]; then
                _argc_die "error: flag \`--password-stdin\` don't accept any value"
            fi
            _argc_index=$((_argc_index + 1))
            if [[ -n "$argc_password_stdin" ]]; then
                _argc_die "error: the argument \`--password-stdin\` cannot be used multiple times"
            else
                argc_password_stdin=1
            fi
            ;;
        --domain | -d)
            _argc_take_args "--domain <DOMAIN>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_domain" ]]; then
                argc_domain="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--domain\` cannot be used multiple times"
            fi
            ;;
        --domain-password)
            _argc_take_args "--domain-password <DOMAIN-PASSWORD>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_domain_password" ]]; then
                argc_domain_password="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--domain-password\` cannot be used multiple times"
            fi
            ;;
        --domain-password-stdin)
            if [[ "$_argc_item" == *=* ]]; then
                _argc_die "error: flag \`--domain-password-stdin\` don't accept any value"
            fi
            _argc_index=$((_argc_index + 1))
            if [[ -n "$argc_domain_password_stdin" ]]; then
                _argc_die "error: the argument \`--domain-password-stdin\` cannot be used multiple times"
            else
                argc_domain_password_stdin=1
            fi
            ;;
        --domain-username)
            _argc_take_args "--domain-username <DOMAIN-USERNAME>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_domain_username" ]]; then
                argc_domain_username="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--domain-username\` cannot be used multiple times"
            fi
            ;;
        -?*)
            _argc_die "error: unexpected argument \`$_argc_key\` found"
            ;;
        *)
            argc__positionals+=("$_argc_item")
            _argc_index=$((_argc_index + 1))
            ;;
        esac
    done
    _argc_require_params "error: the following required arguments were not provided:" \
        'argc_domain:--domain <DOMAIN>'
    if [[ -n "$_argc_action" ]]; then
        $_argc_action
    else
        argc__fn=benchmark
        if [[ "${argc__positionals[0]}" == "help" ]] && [[ "${#argc__positionals[@]}" -eq 1 ]]; then
            _argc_usage_benchmark
        fi
        if [[ -z "$argc_snapshots" ]]; then
            argc_snapshots=1
        fi
        if [[ -z "$argc_period" ]]; then
            argc_period=5
        fi
        if [[ -z "$argc_initial_wait" ]]; then
            argc_initial_wait=5
        fi
        if [[ -z "$argc_fio_ini" ]]; then
            argc_fio_ini=./fio.ini
        fi
        if [[ -z "$argc_block_commit" ]]; then
            argc_block_commit=10
        fi
        if [[ -z "$argc_block_device" ]]; then
            argc_block_device=vda
        fi
    fi
}

_argc_usage_run() {
    cat <<-'EOF'
Run both benchmark and visualise commands

USAGE: naft run [OPTIONS] --domain <DOMAIN> --python-venv <PYTHON-VENV>

OPTIONS:
  -s, --snapshots <SNAPSHOTS>              Number of snapshots to take [default: 1]
      --period <PERIOD>                    Gap between consecutive snapshots [default: 5]
  -i, --initial-wait <INITIAL-WAIT>        Number of seconds to wait for before starting fio [default: 5]
  -f, --fio-ini <FIO-INI>                  Location of the ini configuration file for fio [default: ./fio.ini]
  -b, --block-commit <BLOCK-COMMIT>        Number of seconds to wait for after last snapshot to start block commit [default: 10]
      --block-device <BLOCK-DEVICE>        Block device to perform block-commit [default: vda]
  -p, --password <PASSWORD>                File containing the sudo password in base64 format
      --password-stdin                     Provide sudo password in stdin
  -d, --domain <DOMAIN>                    Name of the VM to run benchmarks on
      --domain-password <DOMAIN-PASSWORD>  File containing the domain password in base64 format
      --domain-password-stdin              Provide domain password password in stdin
      --domain-username <DOMAIN-USERNAME>  Username of the domain user to ssh and scp
      --python-venv <PYTHON-VENV>          Location to python virtual environment to generate graphs
  -h, --help                               Print help
EOF
    exit
}

_argc_parse_run() {
    local _argc_key _argc_action
    local _argc_subcmds=""
    while [[ $_argc_index -lt $_argc_len ]]; do
        _argc_item="${argc__args[_argc_index]}"
        _argc_key="${_argc_item%%=*}"
        case "$_argc_key" in
        --help | -help | -h)
            _argc_usage_run
            ;;
        --)
            _argc_dash="${#argc__positionals[@]}"
            argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
            _argc_index=$_argc_len
            break
            ;;
        --snapshots | -s)
            _argc_take_args "--snapshots <SNAPSHOTS>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_snapshots" ]]; then
                argc_snapshots="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--snapshots\` cannot be used multiple times"
            fi
            ;;
        --period)
            _argc_take_args "--period <PERIOD>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_period" ]]; then
                argc_period="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--period\` cannot be used multiple times"
            fi
            ;;
        --initial-wait | -i)
            _argc_take_args "--initial-wait <INITIAL-WAIT>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_initial_wait" ]]; then
                argc_initial_wait="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--initial-wait\` cannot be used multiple times"
            fi
            ;;
        --fio-ini | -f)
            _argc_take_args "--fio-ini <FIO-INI>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_fio_ini" ]]; then
                argc_fio_ini="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--fio-ini\` cannot be used multiple times"
            fi
            ;;
        --block-commit | -b)
            _argc_take_args "--block-commit <BLOCK-COMMIT>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_block_commit" ]]; then
                argc_block_commit="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--block-commit\` cannot be used multiple times"
            fi
            ;;
        --block-device)
            _argc_take_args "--block-device <BLOCK-DEVICE>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_block_device" ]]; then
                argc_block_device="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--block-device\` cannot be used multiple times"
            fi
            ;;
        --password | -p)
            _argc_take_args "--password <PASSWORD>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_password" ]]; then
                argc_password="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--password\` cannot be used multiple times"
            fi
            ;;
        --password-stdin)
            if [[ "$_argc_item" == *=* ]]; then
                _argc_die "error: flag \`--password-stdin\` don't accept any value"
            fi
            _argc_index=$((_argc_index + 1))
            if [[ -n "$argc_password_stdin" ]]; then
                _argc_die "error: the argument \`--password-stdin\` cannot be used multiple times"
            else
                argc_password_stdin=1
            fi
            ;;
        --domain | -d)
            _argc_take_args "--domain <DOMAIN>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_domain" ]]; then
                argc_domain="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--domain\` cannot be used multiple times"
            fi
            ;;
        --domain-password)
            _argc_take_args "--domain-password <DOMAIN-PASSWORD>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_domain_password" ]]; then
                argc_domain_password="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--domain-password\` cannot be used multiple times"
            fi
            ;;
        --domain-password-stdin)
            if [[ "$_argc_item" == *=* ]]; then
                _argc_die "error: flag \`--domain-password-stdin\` don't accept any value"
            fi
            _argc_index=$((_argc_index + 1))
            if [[ -n "$argc_domain_password_stdin" ]]; then
                _argc_die "error: the argument \`--domain-password-stdin\` cannot be used multiple times"
            else
                argc_domain_password_stdin=1
            fi
            ;;
        --domain-username)
            _argc_take_args "--domain-username <DOMAIN-USERNAME>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_domain_username" ]]; then
                argc_domain_username="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--domain-username\` cannot be used multiple times"
            fi
            ;;
        --python-venv)
            _argc_take_args "--python-venv <PYTHON-VENV>" 1 1 "-" ""
            _argc_index=$((_argc_index + _argc_take_args_len + 1))
            if [[ -z "$argc_python_venv" ]]; then
                argc_python_venv="${_argc_take_args_values[0]}"
            else
                _argc_die "error: the argument \`--python-venv\` cannot be used multiple times"
            fi
            ;;
        -?*)
            _argc_die "error: unexpected argument \`$_argc_key\` found"
            ;;
        *)
            argc__positionals+=("$_argc_item")
            _argc_index=$((_argc_index + 1))
            ;;
        esac
    done
    _argc_require_params "error: the following required arguments were not provided:" \
        'argc_domain:--domain <DOMAIN>' 'argc_python_venv:--python-venv <PYTHON-VENV>'
    if [[ -n "$_argc_action" ]]; then
        $_argc_action
    else
        argc__fn=run
        if [[ "${argc__positionals[0]}" == "help" ]] && [[ "${#argc__positionals[@]}" -eq 1 ]]; then
            _argc_usage_run
        fi
        if [[ -z "$argc_snapshots" ]]; then
            argc_snapshots=1
        fi
        if [[ -z "$argc_period" ]]; then
            argc_period=5
        fi
        if [[ -z "$argc_initial_wait" ]]; then
            argc_initial_wait=5
        fi
        if [[ -z "$argc_fio_ini" ]]; then
            argc_fio_ini=./fio.ini
        fi
        if [[ -z "$argc_block_commit" ]]; then
            argc_block_commit=10
        fi
        if [[ -z "$argc_block_device" ]]; then
            argc_block_device=vda
        fi
    fi
}

_argc_take_args() {
    _argc_take_args_values=()
    _argc_take_args_len=0
    local param="$1" min="$2" max="$3" signs="$4" delimiter="$5"
    if [[ "$min" -eq 0 ]] && [[ "$max" -eq 0 ]]; then
        return
    fi
    local _argc_take_index=$((_argc_index + 1)) _argc_take_value
    if [[ "$_argc_item" == *=* ]]; then
        _argc_take_args_values=("${_argc_item##*=}")
    else
        while [[ $_argc_take_index -lt $_argc_len ]]; do
            _argc_take_value="${argc__args[_argc_take_index]}"
            if [[ -n "$signs" ]] && [[ "$_argc_take_value" =~ ^["$signs"] ]]; then
                break
            fi
            _argc_take_args_values+=("$_argc_take_value")
            _argc_take_args_len=$((_argc_take_args_len + 1))
            if [[ "$_argc_take_args_len" -ge "$max" ]]; then
                break
            fi
            _argc_take_index=$((_argc_take_index + 1))
        done
    fi
    if [[ "${#_argc_take_args_values[@]}" -lt "$min" ]]; then
        _argc_die "error: incorrect number of values for \`$param\`"
    fi
    if [[ -n "$delimiter" ]] && [[ "${#_argc_take_args_values[@]}" -gt 0 ]]; then
        local item values arr=()
        for item in "${_argc_take_args_values[@]}"; do
            IFS="$delimiter" read -r -a values <<<"$item"
            arr+=("${values[@]}")
        done
        _argc_take_args_values=("${arr[@]}")
    fi
}

_argc_require_params() {
    local message="$1" missed_envs item name render_name
    for item in "${@:2}"; do
        name="${item%%:*}"
        render_name="${item##*:}"
        if [[ -z "${!name}" ]]; then
            missed_envs="$missed_envs"$'\n'"  $render_name"
        fi
    done
    if [[ -n "$missed_envs" ]]; then
        _argc_die "$message$missed_envs"
    fi
}

_argc_die() {
    if [[ $# -eq 0 ]]; then
        cat
    else
        echo "$*" >&2
    fi
    exit 1
}

_argc_run "$@"

# ARGC-BUILD }
