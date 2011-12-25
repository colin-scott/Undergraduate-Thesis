#!/homes/network/revtr/ruby-upgrade/bin/ruby

gem 'RubyInline'
require 'inline'

class Example
    inline(:C) do |builder|
        builder.include "<sys/types.h>"
        builder.include "<sys/socket.h>"
        builder.include "<netinet/in.h>"
        builder.include "<arpa/inet.h>"

        builder.prefix %{

        // 10.0.0.0/8
        #define lower10 167772160
        #define upper10 184549375
        // 172.
        #define lower172 2886729728
        #define upper172 2887778303
        // 192.168.0.0/16
        #define lower192 3232235520
        #define upper192 3232301055
        // multicase
        #define lowerMulti 3758096384
        #define upperMulti 4026531839
        // 127.0.0.0/16
        #define lowerLoop 2130706432
        #define upperLoop 2147483647
        // 169.
        #define lower169 2851995648
        #define upper169 2852061183
        // 0.0.0.0
        #define zero 0
        
        }


        builder.c_singleton %{

        // can't call ntoa() directly
        char *ntoa(unsigned int addr) {
            struct in_addr in;
            // convert to default jruby byte order
            addr = ntohl(addr);
            in.s_addr = addr;
            return inet_ntoa(in);
         }

         }

        builder.c_singleton %{

        // can't call aton() directly
        unsigned int aton(const char *addr) {
            struct in_addr in;
            inet_aton(addr, &in);
            // inet_aton() already gets the byte order correct I guess?
            return in.s_addr;
         }

         }

         builder.c_raw_singleton %{
        
         static VALUE in_private_prefix(VALUE addr) {
             char *addr_p = StringValuePtr(addr);
             printf("%s", addr_p);
             //struct in_addr in;
             //inet_aton(addr_p, &in);
             //unsigned int ip = in.s_addr;

             //if( (ip > lower10 && ip < upper10 ) || (ip > lower172 && ip < upper172)
             //                || (ip > lower192 && ip < upper192) ||
             //                (ip > lowerMulti && ip < upperMulti) ||
             //                (ip > lowerLoop && ip < upperLoop) ||
             //                (ip > lower169 && ip < lower169) ||
             //                (ip == zero)) {
             //    return T_TRUE;
             //} else {
             //    return T_FALSE;
             //}
          }
        }
    end

    class << self 
        alias :in_private_prefix? :in_private_prefix
    end
end

if $0 == __FILE__
    puts Example.ntoa(0)
    puts Example.ntoa(1)
    puts Example.aton("1.2.3.4")
    puts Example.in_private_prefix?("0.0.0.0")
    puts Example.in_private_prefix?("192.168.1.1")
    puts Example.in_private_prefix?("1.2.3.4")
end
