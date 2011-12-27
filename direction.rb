
# "Enum" for Directions, e.g. Direction::FORWARD

class Direction
    # make initializer public during class loading (to deal with load ' ' calls)
    public_class_method :new

    # Private ctor
    def initialize(symbol)
        @symbol = symbol
    end

    @@forward = Direction.new(:"forward path")
    @@reverse = Direction.new(:"reverse path")
    @@both = Direction.new(:"bi-directional")
    @@false_positive = Direction.new(:"both paths seem to be working...?")

    def self.FORWARD
        return @@forward
    end

    def self.REVERSE
        return @@reverse
    end

    def self.BOTH
        return @@both
    end

    def self.FALSE_POSITIVE
        return @@false_positive
    end

    def to_s()
        @symbol.to_s
    end

    def eql?(other)
        return false if !other.respond_to?(:symbol)
        @symbol.eql? other.symbol
    end
     
    def hash()
        return @symbol.hash
    end

    def is_forward?()
        return (self.eql? Direction.FORWARD or self.eql? Direction.BOTH)
    end

    def is_reverse?()
        return (self.eql? Direction.REVERSE or self.eql? Direction.BOTH)
    end

    private_class_method :new # singletons

    def symbol
        @symbol
    end

    alias == eql?
end

# some isolation logs still have the old symbols to represent direction
module BackwardsCompatibleDirection
    FORWARD = "forward path"
    REVERSE = "reverse path"
    BOTH =  "bi-directional"
    FALSE_POSITIVE = "both paths seem to be working...?"

    def self.convert_to_new_direction(str)
        case str
        when FORWARD
            return Direction.FORWARD
        when REVERSE
            return Direction.REVERSE
        when BOTH
            return Direction.BOTH
        when FALSE_POSITIVE
            return Direction.FALSE_POSITIVE
        else
            raise "unknown direction #{str}"
        end
    end
end
