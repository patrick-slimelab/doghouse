#!/usr/bin/env node
/**
 * Matrix Event Query Tool
 * Allows Scoob to query the indexed Matrix events from MongoDB
 * 
 * Usage:
 *   query-matrix.js <command> [options]
 * 
 * Commands:
 *   count-events              Count total indexed events
 *   rooms                     List all rooms being indexed
 *   events-from-room <id>     Get events from a specific room
 *   search <text>             Search event content for text
 *   recent <limit>            Get recent events (default 20)
 */

const { MongoClient } = require('mongodb');

const uri = process.env.MONGODB_URI || 'mongodb://mongo:27017';
const dbName = process.env.MONGODB_DB || 'matrix_index';
const collectionName = 'events';

async function queryMatrix() {
  const client = new MongoClient(uri);
  
  try {
    await client.connect();
    const db = client.db(dbName);
    const collection = db.collection(collectionName);
    
    const command = process.argv[2] || 'help';
    
    switch (command) {
      case 'count-events':
        const count = await collection.countDocuments();
        console.log(`Total indexed events: ${count}`);
        break;
        
      case 'rooms':
        const rooms = await collection.distinct('room_id');
        console.log(`Found ${rooms.length} rooms:`);
        rooms.forEach(room => console.log(`  ${room}`));
        break;
        
      case 'events-from-room':
        const roomId = process.argv[3];
        if (!roomId) {
          console.error('Usage: query-matrix.js events-from-room <room_id>');
          process.exit(1);
        }
        const events = await collection.find({ room_id: roomId }).limit(10).toArray();
        console.log(`Found ${events.length} recent events from ${roomId}:`);
        events.forEach(evt => {
          console.log(`  [${evt.origin_server_ts}] ${evt.sender}: ${evt.content?.body || '(no body)'}`);
        });
        break;
        
      case 'search':
        const searchText = process.argv[3];
        if (!searchText) {
          console.error('Usage: query-matrix.js search <text>');
          process.exit(1);
        }
        const matches = await collection.find({
          'content.body': { $regex: searchText, $options: 'i' }
        }).limit(20).toArray();
        console.log(`Found ${matches.length} events matching "${searchText}":`);
        matches.forEach(evt => {
          console.log(`  ${evt.room_id} | ${evt.sender}: ${evt.content?.body}`);
        });
        break;
        
      case 'recent':
        const limit = parseInt(process.argv[3]) || 20;
        const recent = await collection.find().sort({ origin_server_ts: -1 }).limit(limit).toArray();
        console.log(`Last ${limit} events:`);
        recent.forEach(evt => {
          console.log(`  [${new Date(evt.origin_server_ts).toISOString()}] ${evt.room_id} | ${evt.sender}: ${evt.content?.body || '(event)'}`);
        });
        break;
        
      default:
        console.log(`
Query Matrix Event Index

Commands:
  count-events              - Count total indexed events
  rooms                     - List all indexed rooms
  events-from-room <id>     - Get recent events from a room
  search <text>             - Search for text in event bodies
  recent [limit]            - Get recent events (default 20)

Examples:
  query-matrix.js count-events
  query-matrix.js rooms
  query-matrix.js events-from-room '!room:server.com'
  query-matrix.js search 'hello'
  query-matrix.js recent 50
`);
    }
    
  } catch (error) {
    console.error('Error querying MongoDB:', error);
    process.exit(1);
  } finally {
    await client.close();
  }
}

queryMatrix();
