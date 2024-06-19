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

get_active_image() {
    active_image_path=$(virsh domblklist $argc_domain | grep vda | awk '{print $2}')
    active_image=$(basename $active_image_path)
}

delete_snaps() {
    
    # Get the active image. Do not delete that :)
    get_active_image

    # Delete other images
    if [ ! -z "${active_image}" ]; then
        snap_dir=/tmp
        if [ $argc_snapshot_location ]; then
            snap_dir=$argc_snapshot_location
        fi
        find $snap_dir -name 'snap-*' ! -name $active_image -type f -exec rm -f {} +

        if [ $? -eq 0 ]; then
            echo_success "Intermediate snapshots deleted"
        else
            echo_failure "Snapshot deletion failed"
            return 1
        fi
    else
        echo_failure "Not deleteing snapshots"
    fi
    
    return 0
}

echo_success() {
    echo $'\u2714' $1
}

echo_failure() {
    echo $'\u274c' $1
}

prerequisites() {

    # Get the Server IP of the domain
    # get_serverip_from_domain  # Currently not using libvirt anymore
    remote_server=localhost
    remote_port=1122

    run_timestamp=$(date +"%Y%m%d_%H%M%S")
    local folder_path="./results"
    local new_folder_path="results_${run_timestamp}"

    if [ -d "$folder_path" ]; then
        # Folder exists, move it
        if [ $argc_password_stdin ] || [ -z $argc_password ]; then
            sudo --prompt='' -S tar -czf "$new_folder_path.tar.gz" "$folder_path" >/dev/null
        else
            base64 -d $argc_password | sudo --prompt='' -S tar -czf "$new_folder_path.tar.gz" "$folder_path" >/dev/null
        fi
        rm -rf $folder_path >/dev/null
    fi

    if [ -d "$new_folder_path" ]; then
        echo_success "Existing folder zipped to $new_folder_path.tar.gz"
    fi

    # Perform SCP transfer
    
    # The remote path is /tmp. Modify to change
    remote_path="/tmp"
    # Create a results folder 
    ssh $argc_domain_username@$remote_server -p $remote_port "mkdir -p $remote_path/$folder_path" >/dev/null

    scp -P $remote_port "$argc_fio_ini" "$argc_domain_username@$remote_server:$remote_path/$folder_path/$argc_fio_ini" >/dev/null
    
    # Check the exit status of the scp command
    if [ $? -eq 0 ]; then
        echo_success "$argc_fio_ini file transferred"
    else
        echo_failure "SCP of fio.ini failed"
        return 1
    fi

    return 0;
}

start_perf() {
    # Too lazy to handle errors in this function
    if [ $argc_perf_period -eq 0 ]; then
        echo_success "Perf is skipped"
        return 0
    fi

    local event=$1
    local qemu_pid=$(pgrep qemu)
    if [ $argc_password_stdin ] || [ -z $argc_password ]; then
        sudo --prompt='' -S perf record -g --quiet -p $qemu_pid -o perf.$event -F 99 -- sleep $argc_perf_period &
    else
        base64 -d $argc_password | sudo --prompt='' -S perf record -g --quiet -p $qemu_pid -o perf.$event -F 99 -- sleep $argc_perf_period &
    fi
    # perf_pid=$(pgrep perf -n)
    spinner_wait $! "Waiting for perf to terminate"
    echo_success "perf captured to file perf.$event"
    return 0
}

start_fio() {
    # The remote path is /tmp. Modify to change
    remote_path="/tmp/results"
    # Create a results folder 
    ssh "$argc_domain_username@$remote_server" -p $remote_port "mkdir -p $remote_path" >/dev/null

    # Execute commands over SSH
    # Either send the password in a text file, or provide it in stdin.
    # Yes, I know it's not secure, but it does the job for me in an internal system

    if [ $argc_domain_password_stdin ] || [ -z $argc_domain_password ]; then
        fio_clock=$(date +%s)
        fio_pid=$(ssh -tq "$argc_domain_username@$remote_server" -p $remote_port "sudo -S --prompt='' bash -c 'nohup fio --minimal $remote_path/$argc_fio_ini & echo \$!' >/dev/null" >/dev/null)
    else
        fio_clock=$(date +%s)
        fio_pid=$(ssh -tq "$argc_domain_username@$remote_server" -p $remote_port "base64 -d $argc_domain_password | sudo --prompt='' -S bash -c 'nohup fio --minimal $remote_path/$argc_fio_ini & echo \$!' >/dev/null" >/dev/null)
    fi
    fio_pid=$(ssh "$argc_domain_username@$remote_server" -p $remote_port "pgrep fio -n")

    rm -rf /tmp/fio_snap
    rm -rf /tmp/fio_snap_merge
    
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
    local name="snap-$(date +'%d%m%Y')-$(date +%s)"

    if [ -z $argc_snapshot_location ]; then
        snapshot_dir=$(pwd)
    else
        snapshot_dir=$argc_snapshot_location
    fi
    
    # virsh snapshot-create-as --domain $argc_domain $name --diskspec $argc_block_device,file=$snapshot_dir/$name --disk-only --no-metadata >/dev/null
    echo "snapshot_blkdev $argc_block_device $snapshot_dir/$name" | sudo socat - UNIX-CONNECT:$argc_socket_location/qemu-monitor-socket > /dev/null
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

block_stream() {

    echo -n "$(($(date +%s) - $fio_clock))" >> /tmp/fio_snap_merge
    # virsh blockpull $argc_domain $argc_block_device --wait --timeout=$argc_blockstream_timeout & >/dev/null
    echo "block_stream $argc_block_device" | sudo socat - UNIX-CONNECT:$argc_socket_location/qemu-monitor-socket >/dev/null

    while true; do output=$(echo 'info block-jobs' | sudo socat - UNIX-CONNECT:$argc_socket_location/qemu-monitor-socket | grep "No"); if echo "$output" | grep -q "No active jobs"; then break; fi; sleep 1; done &
    blockpull_pid=$!
    start_perf "during_stream"
    spinner_wait $blockpull_pid "Waiting for streaming to terminate"
    echo -n " $(($(date +%s) - $fio_clock))" >> /tmp/fio_snap_merge

    if [ $? -eq 0 ]; then
        echo_success "Block stream successful"
        return 0
    else
        echo_failure "Block stream failed"
        return 1
    fi
}

# @cmd  Generate graphs
# @option   --python-venv!              Location to python virtual environment to generate graphs
# @option   -s --snapshots=1            Number of snapshots taken
visualize() {

    # Generate the graph

    if [[ $argc_block_commit -ne 0 ]]; then
        operation="commit"
    else
        operation="stream"
    fi
    cd results; 
    source $argc_python_venv && fio-plot -i ./ --source "https://triii.github.io/"  -T "Random read & write and block $operation after $argc_snapshots snapshots" -g -t iops --xlabel-parent 0 -n 1 -d 1 -r randrw --vlines /tmp/fio_snap --vspans /tmp/fio_snap_merge --dpi 1000 -w 0.3 >/dev/null; 
    mkdir -p output
    mv *.png output/
    cd ..;
    echo_success "Benchmark graph generated"

}

exit_routines() {
    ssh "$argc_domain_username@$remote_server" -p $remote_port "base64 -d $argc_domain_password | sudo --prompt='' -S bash -c '$(declare -f spinner_wait); spinner_wait $fio_pid \"Waiting for fio\"'"
    # Check the exit status of the SSH command
    if [ $? -eq 0 ]; then
        echo_success "fio completed successfully"
    else
        echo_failure "fio failed"
        return 1
    fi

    # Now copy the results folder
    scp -P $remote_port -r "$argc_domain_username@$remote_server":"$remote_path/$folder_path" ./ >/dev/null
    
    # Check the exit status of the scp command
    if [ $? -eq 0 ]; then
        echo_success "Results folder copied"
    else
        echo_failure "Results folder could not be copied"
        return 1
    fi

    # Copy the perf files to results folder
    mkdir -p results/perf_results >/dev/null
    mkdir -p results/output >/dev/null
    if [ $argc_perf_period -ne 0 ]; then
        mv perf.* results/perf_results >/dev/null
    fi

    # Copy the snap timestamps
    if [ -f /tmp/fio_snap_merge ]; then
        cp /tmp/fio_snap_merge results/ >/dev/null
    fi
    if [ -f /tmp/fio_snap ]; then
        cp /tmp/fio_snap results/ >/dev/null
    fi

    return 0
}

# @cmd  Run benchmarks
# @option   -s --snapshots=1            Number of snapshots to take
# @option   --period=5                  Gap between consecutive snapshots
# @option   -i --initial-wait=5         Number of seconds to wait for before starting fio
# @option   -f --fio-ini=./fio.ini      Location of the ini configuration file for fio
# @option   --block-commit=0            Number of seconds to wait for after last snapshot to start block commit
# @option   --block-stream=10           Number of seconds to wait for after last snapshot to start block pull
# @option   --block-device=vda          Block device to perform block-commit
# @option   -p --password               File containing the sudo password in base64 format
# @flag     --password-stdin            Provide sudo password in stdin
# @option   -d --domain!                Name of the VM to run benchmarks on
# @option   --domain-password           File containing the domain password in base64 format
# @flag     --domain-password-stdin     Provide domain password password in stdin
# @option   --domain-username           Username of the domain user to ssh and scp
# @option   --perf-period=0             How many seconds to run perf
# @option   --snapshot-location         Location to store snapshots
# @option   --blockstream-timeout=90    Timeout in seconds for block commit
# @option   --socket-location=/tmp      Location of QEMU sockets
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
        start_perf "before_snapshot"
        take_snapshots;
        if [ $? -eq 1 ]; then
            echo_failure "Failure taking snapshots. Exiting.."
            return 1
        else
            start_perf "after_snapshot"
        fi
        
    fi

    if [[ $argc_block_commit -ne 0 ]]; then
        sleep $argc_block_commit &
        spinner_wait $! "Waiting to start block commit for $argc_block_commit seconds"
        block_commit;
    elif [[ $argc_block_stream -ne 0 ]]; then
        sleep $argc_block_stream &
        spinner_wait $! "Waiting to start block streaming for $argc_block_stream seconds"
        start_perf "before_stream"
        block_stream;
    else
        echo_success "Skipped block commit or block stream"
    fi
    
    exit_routines;
    if [ $? -eq 1 ]; then
        echo_failure "Exit routines failed. Exiting.."
        return 1
    fi
}

# @cmd    Generate flame graphs from perf record outputs
# @option --stackcollapse=$HOME/bin         Location of stackcollapse and flamegraph programs
# @option --location=./                     Location where flame graphs are located
flame() {

    # Get all files with the prefix "perf." in the current directory
    find . -type f -name "*.svg" -exec rm -f {} \;
    find . -type f -name "*.stack" -exec rm -f {} \;
    file_list=()
    for file in ./$argc_location/**/perf.*; do
        # Check if the file exists
        if [ -f "$file" ]; then
            # Add the file to the array
            file=$(realpath $file)
            file_list+=("$file")
        fi
    done

    # For each file, generate the flame graph
    for file in "${file_list[@]}"; do
        if [ $argc_password_stdin ] || [ -z $argc_password ]; then
            sudo --prompt='' -S perf script -i $file > $file.stack
        else
            base64 -d $argc_password | sudo --prompt='' -S perf script -i $file > $file.stack
        fi
        stackcollapse-perf.pl --all $file.stack | flamegraph.pl > $file.flame.svg
    done

    find . -type f -name "*.stack" -exec rm -f {} \;
    
    mkdir -p $argc_location/output
    find . -type f -name "*.svg" -exec mv {} ./$argc_location/output/ \;

    echo_success "Flame graphs created"

}

# @cmd    Generate a stat file with the fio merge timestamps
# @option   -p --path=../tools/avg_iops.py      Path to the python script
stat() {
    python3.10 $argc_path
    echo_success "Stat file generated in results"
}

# @cmd    Cleanup intermediate snaps
# @option   -d --domain=poseidon            Domain name
# @option   --snapshot-location=/tmp        Location to store snapshots
cleanup() {
    delete_snaps
}



# @cmd  Run both benchmark and visualise commands
# @option   -s --snapshots=1            Number of snapshots to take
# @option   --period=5                  Gap between consecutive snapshots
# @option   -i --initial-wait=5         Number of seconds to wait for before starting fio
# @option   -f --fio-ini=./fio.ini      Location of the ini configuration file for fio
# @option   --block-commit=0            Number of seconds to wait for after last snapshot to start block commit
# @option   --block-stream=10           Number of seconds to wait for after last snapshot to start block pull
# @option   --block-device=drive0       Block device to perform block-commit
# @option   -p --password               File containing the sudo password in base64 format
# @flag     --password-stdin            Provide sudo password in stdin
# @option   -d --domain!                Name of the VM to run benchmarks on
# @option   --domain-password           File containing the domain password in base64 format
# @flag     --domain-password-stdin     Provide domain password password in stdin
# @option   --domain-username           Username of the domain user to ssh and scp
# @option   --python-venv!              Location to python virtual environment to generate graphs
# @option   --perf-period=0             How many seconds to run perf
# @option   --snapshot-location         Location to store snapshots
# @option   --blockstream-timeout=90    Timeout in seconds for block commit
# @option   --socket-location=/tmp      Location of QEMU sockets
run() {
    benchmark;
    visualize;
}


eval "$(argc --argc-eval "$0" "$@")"
