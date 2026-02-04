#!/bin/bash
# Matrix Event Query Tool for Scoob
# 
# Environment variables set automatically:
#   MONGODB_URI - MongoDB connection string (e.g., mongodb://mongo:27017)
#   MONGODB_DB - Database name (matrix_index)
#   MONGODB_COLLECTION_EVENTS - Collection name (events)
#
# Usage:
#   query-matrix.sh help              Show this help
#   query-matrix.sh count             Count indexed events
#   query-matrix.sh rooms             List all indexed rooms
#   query-matrix.sh room <room_id>    Get recent events from a room
#   query-matrix.sh search <text>     Search for text in events
#   query-matrix.sh recent [limit]    Get recent events

MONGODB_URI="${MONGODB_URI:-mongodb://mongo:27017}"
MONGODB_DB="${MONGODB_DB:-matrix_index}"
COLLECTION="${MONGODB_COLLECTION_EVENTS:-events}"

# Use MongoDB connection string to query
# This requires mongosh to be installed, or use kubectl/direct connection
show_help() {
    echo "Matrix Event Query Tool"
    echo ""
    echo "Environment: $MONGODB_URI / $MONGODB_DB"
    echo ""
    echo "Commands:"
    echo "  help                    Show this help"
    echo "  count                   Count all indexed events"
    echo "  rooms                   List all rooms being indexed"
    echo "  room <room_id>          Get recent events from a room"
    echo "  search <text>           Search event bodies"
    echo "  recent [limit]          Get recent events (default 20)"
    echo ""
    echo "To use these commands, mongosh must be installed."
    echo "Or connect directly: mongosh '$MONGODB_URI/$MONGODB_DB'"
    echo ""
    echo "Direct MongoDB Query Examples:"
    echo "  mongosh '$MONGODB_URI/$MONGODB_DB'"
    echo "  db.events.countDocuments()"
    echo "  db.events.distinct('room_id')"
    echo "  db.events.find({room_id: '!room:server'}).limit(10)"
    echo "  db.events.find({'content.body': {\\$regex: 'search text'}}).limit(20)"
}

case "${1:-help}" in
    help)
        show_help
        ;;
    count)
        echo "To count events, run:"
        echo "mongosh '$MONGODB_URI/$MONGODB_DB' --eval 'db.events.countDocuments()'"
        ;;
    rooms)
        echo "To list rooms, run:"
        echo "mongosh '$MONGODB_URI/$MONGODB_DB' --eval 'db.events.distinct(\"room_id\")'"
        ;;
    room)
        ROOM_ID="$2"
        if [[ -z "$ROOM_ID" ]]; then
            echo "Usage: query-matrix.sh room <room_id>"
            exit 1
        fi
        echo "To get events from $ROOM_ID, run:"
        echo "mongosh '$MONGODB_URI/$MONGODB_DB' --eval \"db.events.find({room_id: '$ROOM_ID'}).limit(10)\""
        ;;
    search)
        TEXT="$2"
        if [[ -z "$TEXT" ]]; then
            echo "Usage: query-matrix.sh search <text>"
            exit 1
        fi
        echo "To search for '$TEXT', run:"
        echo "mongosh '$MONGODB_URI/$MONGODB_DB' --eval \"db.events.find({'content.body': {\\\\\\$regex: '$TEXT', \\\\\\$options: 'i'}}).limit(20)\""
        ;;
    recent)
        LIMIT="${2:-20}"
        echo "To get recent $LIMIT events, run:"
        echo "mongosh '$MONGODB_URI/$MONGODB_DB' --eval \"db.events.find().sort({origin_server_ts: -1}).limit($LIMIT)\""
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
