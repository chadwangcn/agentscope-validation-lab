CREATE CONSTRAINT memory_space_id_unique IF NOT EXISTS
FOR (space:MemorySpace) REQUIRE space.id IS UNIQUE;

CREATE CONSTRAINT memory_node_space_id_unique IF NOT EXISTS
FOR (memory:Memory) REQUIRE (memory.memory_space, memory.id) IS UNIQUE;

CREATE INDEX entity_space_id IF NOT EXISTS
FOR (entity:Entity) ON (entity.memory_space, entity.id);

CREATE INDEX event_space_time IF NOT EXISTS
FOR (event:Event) ON (event.memory_space, event.occurred_at);
