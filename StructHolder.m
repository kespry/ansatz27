classdef StructHolder < handle
    %StructHolder Summary of this class goes here
    
    properties
        value
    end
    
    methods
        function this = StructHolder(t)
            this.value = struct();
        end
        
        function setVal(this, index, key, val)
            this.value.(key) = val;
        end
        
        function val = getVal(this, index, key)
            val = this.value.(key);
        end
        
    end
    
end

