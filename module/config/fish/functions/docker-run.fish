function docker-run --description "Run the docker container" \
    --wraps "bash" \
    --argument-names _script_dir
    # if no 'script_dir' argument, use current directory
    test -z "$_script_dir"; or set -l _script_dir (pwd -P)

    set -l _run_script "$_script_dir/run.sh"

    if ! test -x "$_run_script"
        printf "%s is not found or not executable.\n" "$_run_script"
        return 1
    end

    if ! "$_run_script"
        printf "%s script run failed.\n" "$_run_script"
        return 1
    end
end
