
module Lock
    # ensure only one monitor process is running at any one time
    def self.acquire_lock(lock_file)
        @lock = File.open(lock_file, "w")  # don't close the file
        if !@lock.flock(File::LOCK_EX | File::LOCK_NB)
            $stderr.puts "Unable to acquire lock file #{lock_file}! Exiting"
            exit
        end
    end
end
