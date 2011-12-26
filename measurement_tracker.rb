#!/homes/network/revtr/ruby-upgrade/bin/ruby

class MeasurementTracker
  def initialize()
    @bucket_size = 60 # seconds per bucket
    @num_buckets = 10 # number of buckets for measurements  
    @vp2type2buckets = Hash.new{|h,k| h[k] = Hash.new{|h1,k1| h1[k1]=[0]}} # map of key to buckets
    @router2type2buckets = Hash.new{|h,k| h[k] = Hash.new{|h1,k1| h1[k1]=[0]}} # map of key to buckets
    @not_done = true
    @total_meas = 0

    @bucket_mutex = Mutex.new
    
      # add thread to manage buckets
    @THREAD_FLUSHER = Thread.new{
      Thread.current[:name] = "Bucket Manager"
      while (@not_done)
        $LOG.puts "MEAS_TRACKER Shifting buckets (total: #{@total_meas})!"
      @bucket_mutex.synchronize do
        print_meas_max()
        
        @vp2type2buckets.each{|vp, t2b|
          t2b.each{|type, buckets|            
            buckets.insert(0,0)
            buckets.pop if buckets.length > @num_buckets
          }
          t2b.delete_if{|t,b| b.sum == 0}                    
        }
        @vp2type2buckets.delete_if{|vp, t2b| t2b.length == 0}
          
        @router2type2buckets.each{|r, t2b|
                  t2b.each{|type, buckets|            
                    buckets.insert(0,0)
                    buckets.pop if buckets.length > @num_buckets
                  }
                  t2b.delete_if{|t,b| b.sum == 0}                    
                }
        @router2type2buckets.delete_if{|vp, t2b| t2b.length == 0}
        
      end # mutex
      
        sleep(@bucket_size)
      
      end # while
    } # end thread
    
end
  
  def add_meas(type, from, to)
    @total_meas+=1
    @bucket_mutex.synchronize do
      @vp2type2buckets[from][type][0]+=1
      @router2type2buckets[to][type][0]+=1
    end
  end
  
  def print_meas_max()
    max_vp = ""
    max_count = 0
    
    count_sum = 0
    count = 0
    @vp2type2buckets.each{|vp, t2b|
      sum = 0
      t2b.each{|t,b| sum+=b[0]}
        if sum> max_count 
          max_vp = vp
          max_count = sum
        end
        count_sum+=sum
        count+=1
    }
    
    if count > 0 
    $LOG.puts "MEAS_TRACKER: [VP] Max meas per minute: #{max_vp}=>#{max_count} (avg: #{count_sum/count})"
    end
    
    max_vp = ""
       max_count = 0
       
       count_sum = 0
    count = 0
       @router2type2buckets.each{|vp, t2b|
         sum = 0
         t2b.each{|t,b| sum+=b[0]}
           if sum> max_count 
             max_vp = vp
             max_count = sum
           end
           count_sum+=sum
         count+=1
       }
    
    if count > 0 
    $LOG.puts "MEAS_TRACKER: [Router] Max meas per minute: #{max_vp}=>#{max_count} (avg: #{count_sum/count})"
    end
    
  end
  
  def done()
    @not_done = false
    @THREAD_FLUSHER.exit
  end
  
end
