% COPYRIGHT Wolfgang Kuehn 2016 under the MIT License (MIT).
% Origin is https://github.com/decatur/ansatz27.

classdef JSON < handle
    
    properties (Constant)
        isoct = exist('OCTAVE_VERSION', 'builtin') ~= 0;
    end
    
    properties %(Access = private)
        errors
        formatters
        unresolvedRefs
    end
    
    methods

        function this = JSON()
            this.formatters = containers.Map();
        end

        function uri = resolveURIagainstLoadPath(this, uri)
        %resolveURIagainstLoadPath resolves the reference against the base URI and normalizes.
        % See https://tools.ietf.org/html/rfc3986
            try
                r = javaObject('java.net.URI', uri);
            catch e
                error('JSON:URI', 'Could not resolve URI %s because: %s', uri, e.message);
            end

            if isempty(r.getScheme())
                % Relative reference
                base = javaObject('java.net.URI', 'file:/');
                location = which(uri);
                if isempty(location)
                    error('JSON:URI', 'Could not resolve URI %s', uri);
                end
                uri = ['file:/' strrep(location, '\', '/')];
            end
        end

%        function uri = __resolveURI(this, uri)
%        %resolveURI resolves the URI from the load path.
%        % Also does a mild normalization
%        % See https://tools.ietf.org/html/rfc3986
%
%            names = regexp(uri, '^(?<scope>[a-z]+:)(?<authority>//[^/]+)?(?<path>.*)$', 'names', 'once', 'ignorecase');
%            names.scope = lower(names.scope);           % Normalize scope port
%            names.authority = lower(names.authority);   % Normalize authority port
%            if strcmp(names.scope, 'file:') && names.path ~= '/'
%                s = which(names.path);
%                if ~isempty(s)
%                    names.path = which(s);
%                end
%            elseif strcmp(names.scope, 'http:') && ~isempty(names.authority)
%                % Normalize default port
%                names.authority = regexprep(names.authority, ':80$', '');
%            elseif strcmp(names.scope, 'https:') && ~isempty(names.authority)
%                % Normalize default port
%                names.authority = regexprep(names.authority, ':443$', '');
%            end
%            uri = [names.scope names.authority names.path];
%        end

        function schema = loadSchema(this, schema)
            localSchemaCache = containers.Map();
            this.unresolvedRefs = struct([]);   % These are populated by normalizeSchema()

            if ischar(schema)
                schema = strtrim(schema);
                if isempty(schema)
                    schema = [];
                    return;
                elseif isempty(regexp(schema, '^\s*\{')) % A URI cannot start with an opening curly, but a schema will
                    uri = this.resolveURIagainstLoadPath(schema);
                    schema = this.loadSchemaByURI(uri, localSchemaCache);
                else
                    uri = '';
                    schema = this.postLoadSchema(schema, uri);
                    localSchemaCache(uri) = schema;
                end
            elseif isa(schema, 'Map')
                % Do nothing
                uri = '';
                schema(uri) = uri;
            elseif isempty(schema)
                schema = [];
                return;
            else
                error('Invalid type: %s', class(schema));
            end

            this.resolveSchema(localSchemaCache);
            schema = localSchemaCache(uri);
        end

        function resolveSchema(this, localSchemaCache)
            
            while length(this.unresolvedRefs) > 0
                index = length(this.unresolvedRefs);
                ref = this.unresolvedRefs(index);
                s = sprintf('uri[%s] pointer[%s] ref[%s]\n', ref.uri, ref.pointer, ref.ref);
                fprintf(1, 'Processing %s', s);
                parts = strsplit(ref.ref, '#');
                if ~isempty(parts{1})
                    schema1 = this.loadSchemaByURI(parts{1}, localSchemaCache);
                    localSchemaCache(parts{1}) = schema1;
                else
                    schema1 = localSchemaCache(ref.uri);
                end

                schema1 = JSON.getPath(schema1, parts{2});
                if isempty(schema1)
                    error('JSON:PARSE_SCHEMA', 'Invalid $ref at %s', s);
                end

                localSchemaCache(ref.uri) = JSON.setPath(localSchemaCache(ref.uri), ref.pointer, schema1);

                if schema1.isKey('$ref')
                    if ismember(ref.ref, this.unresolvedRefs(index).hist)
                        error('JSON:PARSE_SCHEMA', 'Cyclic references %s', strjoin(this.unresolvedRefs(index).hist, ' -> '));
                    end
                    this.unresolvedRefs(index).hist{end+1} = ref.ref;
                    this.unresolvedRefs(index).ref = schema1('$ref');
                    display(this.unresolvedRefs(index))
                else
                    this.unresolvedRefs = this.unresolvedRefs([1:index-1 index+1:end]);
                end
            end

            % No errors so far. We can now make local schema cache persistent.
            uris = localSchemaCache.keys();
            for k=1:length(uris)
                uri = uris{k};
                schema = localSchemaCache(uri);
                if schema.isKey('allOf')
                    %TODO: At any level
                    this.mergeSchemas(schema);
                end

                if ~isempty(uri)
                    JSON.cacheSchema(uri, schema);
                end
            end
        end
        
        function addError(this, pointer, msg, value, type)
            if nargin < 5
                type = 'JSON:SCHEMA_VALIDATION';
            end
            
            if isstruct(value) || isa(value, 'Map')
                value = '{object}';
            elseif iscell(value)
                value = '[array]';
            elseif islogical(value)
                value = mat2str(value);
            elseif isnumeric(value)
                value = num2str(value);
            end
            this.errors{end+1} = {pointer msg value type};
        end
        
        function childSchema = getPropertySchema(this, schema, key)
            assert(ischar(key));
            
            if isempty(schema) % Shortcut
                childSchema = [];
                return;
            end
            
            childSchema = JSON.getPath(schema, ['/properties/' key]);
            
            if ~isempty(childSchema)
                return;
            end

            if schema.isKey('patternProperties')
                patternProperties = schema('patternProperties');
                patterns = patternProperties.keys();
                for k=1:length(patterns)
                    if ~isempty(regexp(key, patterns{k}))
                        childSchema = patternProperties(patterns{k});
                        break;
                    end
                end
            end

        end

        function childSchema = getItemSchema(this, items, key)
            assert(isnumeric(key) && ~rem(key, 1));
            childSchema = [];
            
            if isempty(items) % Shortcut
                return;
            end
            
            if isa(items, 'Map')
                childSchema = items;
            elseif iscell(items) && key < length(items)
                childSchema = items{key+1};
            end
        end
        
        function mergedSchema = mergeSchemas(this, schema)
            %MERGESCHEMAS Summary of this function goes here
            %   Detailed explanation goes here
            
            % Merge properties and required fields of all schemas.
            mergedSchema = containers.Map();
            mergedSchema('type') = 'object'; % TODO: Why not {'object'}?
            mergedProperties = containers.Map();
            mergedSchema('properties') = mergedProperties;
            mergedSchema('required') = {};
            allOf = schema('allOf');
            
            for k=1:length(allOf)
                subSchema = allOf{k};
                % TODO: Assert properties is member
                props = subSchema('properties');
                keys = props.keys();
                for l=1:length(keys)
                    key = keys{l};
                    mergedProperties(key) = props(key);
                end
                
                if subSchema.isKey('required')
                    if mergedSchema.isKey('required')
                        mergedSchema('required') = [mergedSchema('required') subSchema('required')];
                    else
                        mergedSchema('required') = subSchema('required');
                    end
                end
            end
        end

        function pType = inferePrimitiveType(this, value, schema, pointer)

            type = schema('type');
            pType = [];

            if isempty(type); return; end;

            if isempty(value)
                pType = type{1};
            else
                n = numel(value);

                if ischar(value)
                    if ismember('string', type)
                        pType = 'string';
                    end
                elseif isstruct(value) || isa(value, 'Map')
                    if n==1 && ismember('object', type)
                        pType = 'object';
                    elseif ismember('array', type)
                        pType = 'array';
                    end
                elseif iscell(value)
                    if ismember('array', type)
                        pType = 'array';
                    end
                elseif isnumeric(value)
                    if n == 1
                        if isnan(value) 
                            if ismember('null', type)
                                pType = 'null';
                            end
                        elseif rem(value, 1) == 0 % integer value
                            if ismember('integer', type)
                                pType = 'integer';
                            elseif ismember('number', type) 
                                pType = 'number';
                            end
                        elseif ismember('number', type)
                            pType = 'number';
                        end
                    end

                    if isempty(pType) && ismember('array', type)
                        pType = 'array';
                    end
                elseif islogical(value)
                    if n == 1 && ismember('boolean', type)
                        pType = 'boolean';
                    elseif ismember('array', type)
                        pType = 'array';
                    end
                end

                if isempty(pType)
                    this.addError(pointer, sprintf('does not match type %s', strjoin(type, ' or ')), value);
                    return
                end
            end
        end

        function validate(this, value, pType, schema, pointer)

            function p = getBadPath(pointer, indices)
                isVec = length(indices) > 1;
                indices = find(indices);
                if isempty(indices)
                    p = [];
                elseif isVec
                    p = [pointer num2str(indices)];
                else
                    p = pointer;
                end
            end

            if strcmp(pType, 'object')

                if isstruct(value)
                    s = fieldnames(value);
                else
                    s = value.keys();
                end

                if schema.isKey('required')
                    required = schema('required');
                    for k=1:length(required)
                        if ~ismember(required{k}, s)
                            this.addError(pointer, sprintf('is missing required field %s', required{k}), value);
                        end
                    end
                end

                if schema.isKey('minProperties') && length(s) < schema('minProperties')
                    this.addError(pointer, sprintf('has less than %g properties', schema('minProperties')), value);
                end

                if schema.isKey('maxProperties') && length(s) > schema('maxProperties')
                    this.addError(pointer, sprintf('has more than %g properties', schema('maxProperties')), value);
                end

                if JSON.getPath(schema, '/additionalProperties') == false
                    p = JSON.getPath(schema, '/properties', containers.Map()).keys();
                    s = s(~ismember(s, p));
                    pP = JSON.getPath(schema, '/patternProperties', containers.Map());
                    pp = pP.keys();
                    sFound = {};
                    for l=1:length(pp)
                        pattern = pp{l};
                        for k=1:length(s)
                            if ~isempty(regexp(s{k}, pattern))
                                sFound{end+1} = s{k};
                                break;
                            end
                        end
                    end

                    sNotFound = s(~ismember(s, sFound));
                    for k=1:length(sNotFound)
                        this.addError(pointer, 'contains additional property', sNotFound{k});
                    end
                end

                if schema.isKey('enum')
                    this.addError(pointer, 'is not contained in enumeration', value);
                end

            elseif ischar(value)

                if schema.isKey('pattern') && isempty(regexp(value, schema('pattern')))
                    this.addError(pointer, sprintf('does not match pattern %s', schema('pattern')), value);
                end

                if schema.isKey('minLength') && length(value) < schema('minLength')
                    this.addError(pointer, sprintf('has length less than %g', schema('minLength')), value);
                end

                if schema.isKey('maxLength') && length(value) > schema('maxLength')
                    this.addError(pointer, sprintf('has length greater than %g', schema('maxLength')), value);
                end
                
                format = JSON.getPath(schema, '/format');
                
                if strcmp(format, 'date')
                    if isempty(regexp(value, '^\d{4}-\d{2}-\d{2}$'))
                        this.addError(pointer, 'is not a date', value);
                    end
                end

                if schema.isKey('enum')
                    enum = schema('enum');
                    if ~iscellstr(enum) || ~ismember(value, enum)
                        this.addError(pointer, 'is not contained in enumeration', value);
                    end
                end
                
            elseif ismember(pType, {'integer' 'number'})
                
                if strcmp(pType, 'integer') && rem(value, 1)
                    this.addError(badPath, 'is not an integer', value);
                end

                if schema.isKey('multipleOf') && rem(value, schema('multipleOf'))
                    this.addError(pointer, sprintf('is not a multiple of %g', schema('multipleOf')), value);
                end
                
                if schema.isKey('minimum')
                    if schema.isKey('exclusiveMinimum') && schema('exclusiveMinimum')
                        idx = value <= schema('minimum');
                    else
                        idx = value < schema('minimum');
                    end
                    badPath = getBadPath(pointer, idx);
                    if ~isempty(badPath)
                        this.addError(badPath, sprintf('violates minimum %g', schema('minimum')), value);
                    end
                end
                
                if schema.isKey('maximum')
                    if schema.isKey('exclusiveMaximum') && schema('exclusiveMaximum')
                        idx = value >= schema('maximum');
                    else
                        idx = value > schema('maximum');
                    end
                    badPath = getBadPath(pointer, idx);
                    if ~isempty(badPath)
                        this.addError(badPath, sprintf('violates maximum %g', schema('maximum')), value);
                    end
                end

                if schema.isKey('enum')
                    enum = schema('enum');
                    if ~isnumeric(enum) || ~ismember(value, enum)
                        this.addError(pointer, 'is not contained in enumeration', value);
                    end
                end
                
            elseif strcmp(pType, 'array')
                
                if schema.isKey('additionalItems') && ~schema('additionalItems') && ...
                   schema.isKey('items') && iscell(schema('items')) && length(value)>length(schema('items'))
                    this.addError(pointer, sprintf('does not allow additional items'), '[array]');
                end

                if schema.isKey('minItems') && length(value) < schema('minItems')
                    this.addError(pointer, sprintf('has less than %g items', schema('minItems')), '[array]');
                end
                
                if schema.isKey('maxItems') && length(value) > schema('maxItems')
                    this.addError(pointer, sprintf('has more than %g items', schema('maxItems')), '[array]');
                end

                if schema.isKey('enum')
                    this.addError(pointer, 'is not contained in enumeration', value);
                end
            
            elseif strcmp(pType, 'array')
                if schema.isKey('enum')
                    this.addError(pointer, 'is not contained in enumeration', value);
                end
            elseif strcmp(pType, 'boolean')
                if schema.isKey('enum')
                    enum = schema('enum');
                    if ~islogical(enum) || ~ismember(value, enum)
                        this.addError(pointer, 'is not contained in enumeration', value);
                    end
                end
            end

        end
        
    end % methods
    
    methods (Access=private)

        function schema = loadSchemaByURI(this, uri, localSchemaCache)
            fprintf(1, 'Loading schema from uri %s\n', uri);

            schema = JSON.getSchemaFromCache(uri, localSchemaCache);
            if ~isempty(schema)
                return;
            end

            try
                schema = urlread(uri);
            catch e
                error('JSON:PARSE_SCHEMA', 'Could not read schema from %s because: %s', uri, e.message);
            end

            if isempty(strtrim(schema))
                % libcurl will return empty string if file uri points to directory.
                error('JSON:PARSE_SCHEMA', 'No schema at %s', uri);
            end

            schema = this.postLoadSchema(schema, uri);
            localSchemaCache(uri) = schema;
        end

        function resolvedURI = resolveURI(this, uri, base)
        %resolveURI resolves the reference against the base URI.
        % See https://tools.ietf.org/html/rfc3986
            resolvedURI = uri;
            if ~isempty(base)
                base = javaObject('java.net.URI', base);
                resolvedURI = char(base.resolve(uri));
            end
        end

        function schema = postLoadSchema(this, schema, uri)
            schema = JSON.parse(schema, [], struct('objectFormat', 'Map'));
            schema('uri') = uri;

            if ~schema.isKey('id')
                % [7.1 Core] The initial resolution scope of a schema is the URI of the schema itself, if any, or the empty URI if the schema was not loaded from a URI.
                schema('id') = uri;
            end

            this.normalizeSchema(schema, '', schema('id'));
        end

        function normalizeSchema(this, rootSchema, pointer, resolutionScope)
        %normalizeSchema breadth first traverses the given schema and validates all subschemas.

            function addSchema(schema, pointer, resolutionScope)
                schemaInfos{end+1} = struct('schema', schema, 'pointer', pointer, 'resolutionScope', resolutionScope);
            end

            function processProperties(propertyType, schema, pointer, resolutionScope)
                if schema.isKey(propertyType) && ~isempty(schema(propertyType))
                    props = schema(propertyType);
                    pNames = props.keys();
                    for k=1:length(pNames)
                        subPath = [pointer '/' propertyType '/' pNames{k}];
                        addSchema(props(pNames{k}), subPath, resolutionScope);
                    end
                end
            end

            schemaInfos = {};

            addSchema(rootSchema, pointer, resolutionScope);

            while ~isempty(schemaInfos)
                info = schemaInfos{end};
                schemaInfos = schemaInfos(1:end-1);
                schema = info.schema;
                resolutionScope = info.resolutionScope;
                pointer = info.pointer;

                %display(info);

                if ~isa(schema, 'Map')
                    error('JSON:PARSE_SCHEMA', 'A JSON Schema MUST be an object');
                end
                
                if schema.isKey('$ref')
                    %schema = this.resolveRef(rootSchema, schema, pointer, resolutionScope);
                    ref = schema('$ref');
                    if ~ischar(ref)
                        % TODO: use addError and make that throw
                        error('JSON:PARSE_SCHEMA', '$ref must be a string at %s', pointer);
                    end
                    ref = this.resolveURI(ref, resolutionScope);

                    if isempty(strfind(ref, '#'))
                        ref = [ref '#']
                    end

                    schema('$ref') = ref;

                    ref = struct('uri', rootSchema('uri'), 'pointer', pointer, 'ref', ref); 
                    ref.hist = {};
                    display(ref);
                    this.unresolvedRefs(end+1) = ref;
                end

                if schema.isKey('id') && ~isempty(schema('id'))
                    % Change resolution scope.
                    % Note that we do this AFTER processing $ref. 
                    resolutionScope = this.resolveURI(schema('id'), resolutionScope);
                    if ~javaObject('java.net.URI', resolutionScope).isAbsolute()
                        error('JSON:PARSE_SCHEMA', 'Resolved URI must be absolute: %s', resolutionScope);
                    end
                end

                if schema.isKey('allOf')
                    allOf = schema('allOf');
                    for k=1:length(allOf)
                        subPath = [pointer '/allOf/' num2str(k-1)];
                        addSchema(allOf{k}, subPath, resolutionScope);
                    end
                end
                
                if ~schema.isKey('type') || isempty(schema('type'))
                    schema('type') = {};
                end
                
                type = schema('type');
                
                if ischar(type)
                    type = {type};
                    schema('type') = type;
                end
                            
                if schema.isKey('required') && ~iscell(schema('required'))
                    error('JSON:PARSE_SCHEMA', 'Invalid required at %s', pointer);
                end

                if schema.isKey('pattern') && ~ischar(schema('pattern'))
                    error('JSON:PARSE_SCHEMA', 'Pattern must be a string at %s', pointer);
                end

                processProperties('properties', schema, pointer, resolutionScope);
                processProperties('patternProperties', schema, pointer, resolutionScope);

                if ismember('array', type) && schema.isKey('items') % TODO: Remove first test
                    items = schema('items'); % Remember: Cell array has copy semantic
                    if isa(items, 'Map')
                        addSchema(items, [pointer '/items'], resolutionScope);
                    elseif iscell(items)
                        for k=1:length(items)
                            subPath = [pointer '/items/' num2str(k)];
                            addSchema(items{k}, subPath, resolutionScope);
                        end
                    end
                end

                if schema.isKey('definitions')
                    definitions = schema('definitions');
                    names = definitions.keys();
                    for k=1:length(names)
                        subPath = [pointer '/definitions/' names{k}];
                        addSchema(definitions(names{k}), subPath, resolutionScope);
                    end
                end

                if any(ismember({'number' 'integer'}, type))
                    %if isfield(schema, 'enum') && iscell(schema.enum)
                    %    if all(cellfun(@isnumeric, schema.enum))
                    %        schema.enum = cell2mat(schema.enum);
                    %    end
                    %end
                end
            end % while
            
        end

        function schema = resolveRef(this, rootSchema, schema, pointer, resolutionScope)
            %resolveRef swaps in the referenced schema.
            refs = {};

            while schema.isKey('$ref')
                ref = schema('$ref');
                if isempty(findstr(ref, '#'))
                    ref(end+1) = '#';
                end
                
                if ~ischar(ref) || isempty(strtrim(ref))
                    error('JSON:PARSE_SCHEMA', 'Invalid $ref at %s', strjoin(refs, ' -> '));
                end
                
                ref = strtrim(ref);
                uri = this.resolveURI(ref, resolutionScope);
                
                if ismember(uri, refs)
                    error('JSON:PARSE_SCHEMA', 'Cyclic references %s', strjoin([refs ref], ' -> '));
                end
                
                refs{end+1} = uri;
                
                parts = strsplit(uri, '#');
                assert(length(parts) == 2);
                url = parts{1};
                pointer = parts{2};

                if ~isempty(url)
                    rootSchema = JSON.getSchemaFromCache(url);
                    if isempty(rootSchema)
                        rootSchema = this.loadSchemaByURI(url);
                        rootSchema = this.normalizeSchema(rootSchema);
                        JSON.cacheSchema(url, rootSchema);
                    end
                    schema = rootSchema;
                end

                if ~isempty(pointer)
                    schema = JSON.getPath(rootSchema, pointer);
                    schema = this.normalizeSchema_(schema, schema, pointer, resolutionScope);  
                    if isempty(schema)
                        error('JSON:PARSE_SCHEMA', 'Invalid $ref at %s', strjoin(refs, ' -> '));
                    end
                end

            end
        end

    end % methods (Access=private)

    methods (Static)
        
        function value = configParam(key, value)
            persistent config
            if isempty(config)
                config = struct();
            end

            if nargin == 1
                if isfield(config, key)
                    value = config.(key);
                else
                    value = [];
                end
            elseif nargin == 2
                config.(key) = value;
            else
                value = config;
            end
        end

        function cache = getSchemaCache()
        %getSchemaCache returns the schema cache and lazily creates it.
            cache = JSON.configParam('cache');
            if isempty(cache)
                cache = JSON.configParam('cache', containers.Map());
            end
        end

        function schema = getSchemaFromCache(uri, localSchemaCache)
            if localSchemaCache.isKey(uri)
                schema = localSchemaCache(uri);
                return;
            end

            cache = JSON.getSchemaCache();
            if cache.isKey(uri)
                % Cache hit
                schema = cache(uri);
            else
                schema = [];
            end
        end

        function cacheSchema(uri, schema)
            cache = JSON.getSchemaCache();
            cache(uri) = schema;
        end

%        function value = setBaseURI(baseURI)
%            value = JSON.configParam('baseURI', strrep(baseURI, '\', '/'));
%        end

%        function value = getBaseURI()
%            value = JSON.configParam('baseURI');
%            if isempty(value)
%                if exist('ctfroot', 'builtin') ~= 0
%                    baseURI = ['file:' ctfroot];
%                else
%                    baseURI = ['file:' pwd()];
%                end
%                value = JSON.setBaseURI(baseURI);
%            end
%        end

        function [value, errors] = parse(varargin)
            parser = JSON_Parser();
            
            try
                value = parser.parse_(varargin{:});
            catch e
                if 1 == regexp(e.identifier, '^JSON:', 'once')
                    value = [];
                    parser.addError([], e.message, [], e.identifier);
                else
                    for k=1:numel(e.stack)
                        e.stack(k)
                    end
                    rethrow(e);
                end
            end
            
            errors = parser.errors;
        end
        
        function [json, errors] = stringify(varargin)
            stringifier = JSON_Stringifier();
            
            try
                json = stringifier.stringify_(varargin{:});
            catch e
                if 1 == regexp(e.identifier, '^JSON:', 'once')
                    json = [];
                    stringifier.addError([], e.message, [], e.identifier);
                else
                    for k=1:numel(e.stack)
                        e.stack(k)
                    end
                    rethrow(e);
                end
            end
            
            errors = stringifier.errors;
        end
        
        function obj = setPath(obj, pointer, value)
        %SETPATH sets the value referenced by the pointer.
        % Example
        %   m = containers.Map()
        %   c = m('foo') = containers.Map();
        %   c('bar') = {1 2 3};
        %   JSON.setPath(m, '/foo/bar/1', 42)   -> replaces 2 by 42

            if isempty(pointer)
                obj = value;
            else
                tokens = strsplit(pointer, '/');
                [oldValue, chain] = JSON.getPath(obj, pointer);
                
                c = chain{end};
                if iscell(c)
                    k = length(chain);
                    idx = struct('type', '{}');
                    idx.subs = {};
                    while iscell(c) && k >= 1
                        index = str2double(tokens{k+1});
                        if ischar(index) || isnan(index)
                            error('cell array must be indexed by a positive integer, was %s', tokens{k+1});
                        end
                        idx.subs = [(index+1) idx.subs];
                        k = k-1;
                        if k==0
                            break
                        else
                            c = chain{k};
                        end
                    end

                    if k==0
                        obj = subsasgn(c, idx, value);
                    else
                        % Octave Bug(?): Without builtin, and if value is of class Map,
                        % then subsasgn() calls Map.subsasgn(), even if the lhs c(tokens{k+1})
                        % is not a Map (confirmed with a cell array).
                        c(tokens{k+1}) = builtin ('subsasgn', c(tokens{k+1}), idx, value);
                    end
                else
                    assert(isa(c, 'Map'));
                    c(tokens{end}) = value;
                end
            end
        end

        function [obj, chain] = getPath(obj, pointer, default)
            %GETPATH returns the value referenced by the pointer.
            % The pointer must be a JSON pointer, so each reference token must be
            % prefixed by / and numerical tokens referencing an array are zero-based.
            % Returns default or empty if the pointer does not resolve.
            % See https://tools.ietf.org/html/rfc6901
            %
            % Examples:
            %    obj = containers.Map();
            %    obj('foo') = struct('bar', 13);
            %    obj('bar') = {'foo' 'bar'};
            %    obj('foo/bar') = 42;                   % Not recommended! 
            %    JSON.getPath(obj, '/foo/bar')          % -> 13
            %    JSON.getPath(obj, '/bar/1')            % -> 'bar'
            %    JSON.getPath(obj, '/foo~1bar')         % -> 42
            %    JSON.getPath(obj, '/foobar', 4711)     % -> 4711

            chain = {};

            if isempty(pointer)
                if isempty(obj)
                    obj = default;
                end
                return;
            end

            if pointer(1) ~= '/'
                % TODO: Do not throw here
                error('Invalid pointer syntax for %s', pointer);
            end

            tokens = strsplit(pointer, '/');

            for k = 2:length(tokens)
                chain{end+1} = obj;
                token = tokens{k};
                % '~' needs to be encoded as '~0' and '/' needs to be encoded as '~1'
                token = strrep(strrep(token, '~0', '~'), '~1', '/');
                
                if isa(obj, 'Map') && obj.isKey(token)
                    obj = obj(token);
                    continue;
                end

                if iscell(obj) && 1 == regexp(token, '^\d+$', 'once')
                    l = str2double(token);
                    if l < length(obj) % This will also handle l is not a number
                        obj = obj{l+1};
                        continue;
                    end
                end

                if isstruct(obj) && isfield(obj, token)
                    obj = obj.(token);
                    continue;
                end

                if nargin >= 3
                    obj = default;
                else
                    obj = [];
                end
                break;
            end

        end

        function text = ___readFileToString(pointer, encoding )
            if JSON.isoct
                [fid, msg] = fopen(pointer, 'r');
            else
                [fid, msg] = fopen(pointer, 'r', 'l', encoding);
            end
            
            if fid == -1
                % TODO: Do not throw here
                error('Could not open %s: %s', pointer, msg);
            end
            
            text = fscanf(fid, '%c');
            fclose(fid);
        end
        
        function [s, err] = datenum2string(n)
            if ~isnumeric(n) || rem(n, 1)~=0
                s = n;
                err = 'must be an integer';
                return;
            else
                err = [];
                s = datestr(n, 'yyyy-mm-dd');
            end
        end
        
        function [s, err] = datetimenum2string(n)
            if ~isnumeric(n)
                s = n;
                err = 'must be a number';
                return;
            end
            d = javaObject('java.util.Date', round((n - 719529)*1000*60*60*24));
            d = javaObject('java.util.Date', d.getTime() + d.getTimezoneOffset()*60*1000);
            df = javaObject('java.text.SimpleDateFormat', 'yyyy-MM-dd''T''HH:mm:ssXXX');
            s = char(df.format(d));
            err = [];
        end
        
        function [d, err] = datestring2num(s)
            % Parse date into a numerical date according MATLABs datenum().
            % The argument is returned if it is not a valid date.
            %
            % Example: '2016-01-26'
            
            m = regexp(s, '^(\d{4})-(\d{2})-(\d{2})$', 'tokens', 'once');
            
            if isempty(m)
                d = s;
                err = 'is not a valid date';
                return
            else
                d = datenum(str2double(m{1}),str2double(m{2}),str2double(m{3}));
                err = [];
            end
        end
        
        function [d, err] = datetimestring2num(s)
            % Parse ISO8601 date-time into a numerical date according MATLABs datenum() with respect to the default timezone.
            % Minutes and seconds are optional. Timezone offset is Z (meaning +00:00) or of the form +-02:00 or +-0200.
            % An error is returned if the argument is not a valid date-time.
            %
            % Example:
            %     JSON.datetimestring2num('2016-02-02T00:00:00+01:00')
            %     -> 736362 % Note: Only if default time zone is GMT!
            tokens = regexp(s, '^(.*T\d{2})(:\d{2})?(:\d{2})?(.*)$', 'tokens', 'once');
            
            if isempty(tokens)
                d = s;
                err = 'is not a valid date-time';
                return;
            end
            
            if length(tokens{end}) == 5
                tzf = 'Z'; % RFC 822 time zone -0800
            else
                tzf = 'XXX'; %  ISO 8601 time zone -08:00
            end
            
            fmts = {'', ':mm', ':mm:ss'};
            fmt = ['yyyy-MM-dd''T''HH' fmts{length(tokens)-1} tzf];
            
            df = javaObject('java.text.SimpleDateFormat', fmt);
            try
                d = df.parse(s);
            catch e
                d = s;
                err = 'is not a valid date-time';
                return;
            end
            
            % datenum('1970-01-01') == 719529
            d = (d.getTime()/1000/60 - d.getTimezoneOffset())/60/24 + 719529;
            err = [];
        end


        
    end
end


