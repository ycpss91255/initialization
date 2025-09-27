function docker-build-run --description "Build and run the docker container" \
    --wraps "bash" \
    --argument-names _script_dir
    # if no 'script_dir' argument, use current directory
    test -z "$_script_dir"; or set -l _script_dir (pwd -P)

    set -l _script_name "build.sh" "run.sh"

    for _script in $_script_dir/$_script_name
        # check if script exists and is executable
        if ! test -x "$_script"
            printf "%s is not found or not executable.\n" "$_script"
            return 1
        end
    end

    if ! docker system prune -f
        printf "Docker system prune failed.\n"
        return 1
    end

    set -l _build_script "$_script_dir/$_script_name[1]"

    if ! "$_build_script"
        printf "%s run failed.\n" "$_build_script"
        return 1
    end

    clear

    set -l run_script "$_script_dir/$_script_name[2]"

    if ! "$_run_script"
        printf "%s run failed.\n" "$_run_script"
        return 1
    end
end
