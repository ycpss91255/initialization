function docker-build-run --description "Build and run the docker container"
    set script_dir (if test (count $argv) -gt 0; echo $argv[1]; else; pwd; end)

    docker system prune -f

    $script_dir/build.sh &&
    clear &&
    $script_dir/run.sh
end
