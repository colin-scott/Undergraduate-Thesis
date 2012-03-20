
# Intended for interactive use 

require 'log_filterer'

def parse_options()
    options = OptsParser.new
    
    options.on('-a', '--display_attribute ATTR',
               "Rather than displaying the whole outage, only show the given attribute (e.g. 'src')") do |attr_name|
        options[:attr] = attr_name
    end
    
    options.on('-f', '--filter FILTER',
               "Only consider outages where the given filter was triggered. FILTER is one of the names from aggregate_filter_stats.rb") do |filter|
        filter = filter.to_sym
        options[:predicates].merge!(Predicates.TriggeredFilter(filter))
    end
    
    options.on('-P', '--passed',
               "Set pre-defined predicate for examining outages which passed filters") do |t|
        options[:predicates].merge!(Predicates.PassedFilters)
    end

    options[:time_start] = Time.now - 24*60*60
    options.on( '-t', '--time_start TIME',
             "Filter outages before TIME (of the form 'YYYY.MM.DD [HH.MM.SS]'). [default last day]") do |time|
        options[:time_start] = Time.parse time
    end
    
    options.parse!.display
    
    options
end
