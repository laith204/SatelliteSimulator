classdef ScenarioManager < handle
    % ScenarioManager - wrapper around satelliteScenario for DTN GUI
    %
    % Responsibilities:
    %   - Own the satelliteScenario
    %   - Add/remove satellites and ground stations
    %   - Keep a simple node list (name, type, handle, lat/lon/alt)
    %   - Maintain access objects (for viewer lines) BETWEEN SATELLITES ONLY
    %   - Provide lat/lon/alt and XYZ lookup at a given time
    
    properties
        sc             % satelliteScenario
        nodes          % struct array of nodes
        accesses       % struct array of access objects (sat-sat only)
        startTime      datetime
        stopTime       datetime
        sampleTime     double
    end
    
    methods
        function obj = ScenarioManager(startTime, stopTime, sampleTime)
            % Constructor
            
            obj.startTime  = startTime;
            obj.stopTime   = stopTime;
            obj.sampleTime = sampleTime;
            
            obj.sc = satelliteScenario(startTime, stopTime, sampleTime);
            
            obj.nodes    = struct('name',{},'type',{},'handle',{}, ...
                                  'latDeg',{},'lonDeg',{},'altM',{});
            obj.accesses = struct('nodeA',{},'nodeB',{},'handle',{});
        end
        
        function addSatellite(obj, name, altKm, incDeg, raanDeg)
            % addSatellite - create a simple circular LEO satellite
            %
            % altKm: altitude above Earth in km
            % incDeg, raanDeg: inclination and RAAN in degrees
            
            if obj.hasNode(name)
                error('Node with name %s already exists.', name);
            end
            
            Re = 6371e3;          % Earth radius in meters (approx)
            altM = altKm * 1e3;
            sma  = Re + altM;     % semi-major axis
            ecc  = 0;
            argPeri  = 0;
            trueAnom = 0;
            
            sat = satellite(obj.sc, sma, ecc, incDeg, raanDeg, argPeri, trueAnom, ...
                'Name', name);
            
            node.name   = name;
            node.type   = 'sat';
            node.handle = sat;
            node.latDeg = NaN;
            node.lonDeg = NaN;
            node.altM   = altM;
            
            obj.nodes(end+1) = node;
            
            obj.createAccessesForNewNode(name);
        end
        
        function addGroundStation(obj, name, latDeg, lonDeg, altM)
            % addGroundStation - create a groundStation
            %
            % We DO NOT create any access() involving ground stations
            % to avoid internal satelliteScenarioViewer bugs.
            
            if obj.hasNode(name)
                error('Node with name %s already exists.', name);
            end
            
            gs = groundStation(obj.sc, ...
                'Name',      name, ...
                'Latitude',  latDeg, ...
                'Longitude', lonDeg, ...
                'Altitude',  altM);
            
            node.name   = name;
            node.type   = 'gs';
            node.handle = gs;
            node.latDeg = latDeg;
            node.lonDeg = lonDeg;
            node.altM   = altM;
            
            obj.nodes(end+1) = node;
            
            % NOTE: no access() created for GS; only sat-sat in createAccessesForNewNode
        end
        
        function removeNode(obj, name)
            % removeNode - delete node and its accesses
            
            idx = obj.findNodeIndex(name);
            if isempty(idx)
                return;
            end
            
            h = obj.nodes(idx).handle;
            try
                delete(h);
            catch
            end
            
            % Remove related access objects
            toDelete = false(1, numel(obj.accesses));
            for k = 1:numel(obj.accesses)
                if strcmp(obj.accesses(k).nodeA, name) || ...
                   strcmp(obj.accesses(k).nodeB, name)
                    toDelete(k) = true;
                    try
                        delete(obj.accesses(k).handle);
                    catch
                    end
                end
            end
            obj.accesses(toDelete) = [];
            
            obj.nodes(idx) = [];
        end
        
        function tf = hasNode(obj, name)
            % hasNode - true if node with this name exists
            names = obj.getNodeNames();
            tf = any(strcmp(names, name));
        end
        
        function names = getNodeNames(obj)
            % getNodeNames - return cell array of node names
            names = {obj.nodes.name};
        end
        
        function idx = findNodeIndex(obj, name)
            % findNodeIndex - return index of node with given name
            idx = [];
            for k = 1:numel(obj.nodes)
                if strcmp(obj.nodes(k).name, name)
                    idx = k;
                    return;
                end
            end
        end
        
        function [latDeg, lonDeg, altM] = getLatLonAlt(obj, name, t)
            % getLatLonAlt - get lat/lon/alt of node at time t
            %
            % For satellites: use states(handle, t, 'CoordinateFrame','geographic')
            % For ground stations: they are fixed, so just return stored lat/lon/alt.
            
            idx = obj.findNodeIndex(name);
            if isempty(idx)
                error('Node %s not found.', name);
            end
            
            node = obj.nodes(idx);
            
            if strcmp(node.type, 'gs')
                % Ground station: constant position
                latDeg = node.latDeg;
                lonDeg = node.lonDeg;
                altM   = node.altM;
            else
                % Satellite: use states with geographic frame
                pos = states(node.handle, t, 'CoordinateFrame', 'geographic');
                pos = squeeze(pos);  % [3 x 1] = [lat; lon; alt]
                
                latDeg = pos(1);
                lonDeg = pos(2);
                altM   = pos(3);
            end
        end
        
        function [xKm, yKm, zKm] = getXYZ(obj, nodeName, t)
            % getXYZ - position in km for DTN geometry / LOS tests
            %
            % For satellites: use states(handle, t) in meters.
            % For ground stations: compute simple ECEF from stored lat/lon/alt.
            
            idx = obj.findNodeIndex(nodeName);
            if isempty(idx)
                error('Node %s not found in ScenarioManager.', nodeName);
            end
            node = obj.nodes(idx);
            
            if strcmp(node.type, 'gs')
                % Ground station: approximate ECEF from lat/lon/alt
                ReKm   = 6371;                    % Earth radius in km
                altKm  = node.altM / 1000;
                latRad = deg2rad(node.latDeg);
                lonRad = deg2rad(node.lonDeg);
                r      = ReKm + altKm;
                
                xKm = r * cos(latRad) * cos(lonRad);
                yKm = r * cos(latRad) * sin(lonRad);
                zKm = r * sin(latRad);
            else
                % Satellite: use states() from satelliteScenario
                pos = states(node.handle, t);   % [3 x 1 x 1] in meters
                pos = squeeze(pos);
                
                xKm = pos(1) / 1000;
                yKm = pos(2) / 1000;
                zKm = pos(3) / 1000;
            end
        end
    end
    
    methods (Access = private)
        function createAccessesForNewNode(obj, newName)
            % createAccessesForNewNode - create access objects with all
            % existing nodes when a new SATELLITE node is added.
            %
            % IMPORTANT:
            %   To avoid MATLAB internal bugs in satelliteScenarioViewer
            %   related to GroundStation/updateVisualizations, we ONLY
            %   create access() objects between SATELLITES. We do NOT
            %   create access objects that involve ground stations.
            
            idxNew = obj.findNodeIndex(newName);
            if isempty(idxNew)
                return;
            end
            
            newNode = obj.nodes(idxNew);
            
            for k = 1:numel(obj.nodes)
                if k == idxNew
                    continue;
                end
                
                otherNode = obj.nodes(k);
                
                % Only create access between satellites; skip anything with GS
                if strcmp(newNode.type, 'gs') || strcmp(otherNode.type, 'gs')
                    continue;
                end
                
                aName = otherNode.name;
                bName = newNode.name;
                
                % Avoid duplicates
                if obj.hasAccessBetween(aName, bName)
                    continue;
                end
                
                aHandle = otherNode.handle;
                bHandle = newNode.handle;
                
                acHandle = access(aHandle, bHandle);
                
                entry.nodeA  = aName;
                entry.nodeB  = bName;
                entry.handle = acHandle;
                
                obj.accesses(end+1) = entry;
            end
        end
        
        function tf = hasAccessBetween(obj, nameA, nameB)
            tf = false;
            for k = 1:numel(obj.accesses)
                a = obj.accesses(k).nodeA;
                b = obj.accesses(k).nodeB;
                if (strcmp(a, nameA) && strcmp(b, nameB)) || ...
                   (strcmp(a, nameB) && strcmp(b, nameA))
                    tf = true;
                    return;
                end
            end
        end
    end
end
