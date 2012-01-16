#!/usr/bin/ruby -w

def time2year_month_day(time)
    # 2011.56

    year, week = time.split(".").map { |i| i.to_i }

    month = (week / 4) + 1

    day = (week % 4) * 7

    "#{year}.#{month}.#{day}"
end

File.foreach(ARGV.shift) do |line|
    time, count = line.chomp.split

    puts "#{time2year_month_day(time)} #{count}"
end
