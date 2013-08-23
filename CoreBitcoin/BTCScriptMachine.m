// Oleg Andreev <oleganza@gmail.com>

#import "BTCScriptMachine.h"
#import "BTCScript.h"
#import "BTCOpcode.h"
#import "BTCTransaction.h"
#import "BTCTransactionInput.h"
#import "BTCTransactionOutput.h"
#import "BTCBigNumber.h"
#import "BTCErrors.h"
#import "BTCUnitsAndLimits.h"
#import "BTCData.h"

@interface BTCScriptMachine ()

// Constants
@property(nonatomic) NSData* blobFalse;
@property(nonatomic) NSData* blobZero;
@property(nonatomic) NSData* blobTrue;
@property(nonatomic) BTCBigNumber* bigNumberZero;
@property(nonatomic) BTCBigNumber* bigNumberOne;
@property(nonatomic) BTCBigNumber* bigNumberFalse;
@property(nonatomic) BTCBigNumber* bigNumberTrue;
@end

// We try to match BitcoinQT code as close as possible to avoid subtle incompatibilities.
// The design might not look optimal to everyone, but I prefer to match the behaviour first, then document it well,
// then refactor it with even more documentation for every subtle decision.
// Think of an independent auditor who has to read several sources to check if they are compatible in every little
// decision they make. Proper documentation and cross-references will help this guy a lot.
@implementation BTCScriptMachine {
    
    // Stack contains NSData objects that are interpreted as numbers, bignums, booleans or raw data when needed.
    NSMutableArray* _stack;
    
    // Used in ALTSTACK ops.
    NSMutableArray* _altStack;
    
    // Holds an array of @YES and @NO values to keep track of if/else branches.
    NSMutableArray* _conditionStack;
    
    // Keeps number of executed operations to check for limit.
    NSInteger _opCount;
    
    // Index of last OP_CODESEPARATOR
    NSUInteger _lastCodeSeparatorIndex;
}

- (id) init
{
    if (self = [super init])
    {
        // Constants used in script execution.
        _blobFalse = [NSData data];
        _blobZero = _blobFalse;
        uint8_t one = 1;
        _blobTrue = [NSData dataWithBytes:(void*)&one length:1];
        
        _bigNumberZero = [[BTCBigNumber alloc] initWithInt32:0];
        _bigNumberOne = [[BTCBigNumber alloc] initWithInt32:1];
        _bigNumberFalse = _bigNumberZero;
        _bigNumberTrue = _bigNumberOne;

        _inputIndex = 0xFFFFFFFF;
        _blockTimestamp = (uint32_t)[[NSDate date] timeIntervalSince1970];
        [self resetStack];
    }
    return self;
}

- (void) resetStack
{
    _stack = [NSMutableArray array];
    _altStack = [NSMutableArray array];
    _conditionStack = [NSMutableArray array];
    _opCount = 0;
}

- (id) initWithTransaction:(BTCTransaction*)tx inputIndex:(uint32_t)inputIndex
{
    if (!tx) return nil;
    if (inputIndex >= tx.inputs.count) return nil;
    if (self = [self init])
    {
        _transaction = tx;
        _inputIndex = inputIndex;
    }
    return self;
}

- (id) copyWithZone:(NSZone *)zone
{
    BTCScriptMachine* sm = [[BTCScriptMachine alloc] init];
    sm.transaction = self.transaction;
    sm.inputIndex = self.inputIndex;
    sm.blockTimestamp = self.blockTimestamp;
    sm.verificationFlags = self.verificationFlags;
    sm->_stack = [_stack mutableCopy];
    return sm;
}

- (BOOL) shouldVerifyP2SH
{
    return (_blockTimestamp >= BTC_BIP16_TIMESTAMP);
}

- (BOOL) verifyWithOutputScript:(BTCScript*)outputScript error:(NSError**)errorOut
{
    // Sanity check: transaction and its input should be consistent.
    if (!(self.transaction && self.inputIndex < self.transaction.inputs.count))
    {
        [NSException raise:@"BTCScriptMachineException"  format:@"transaction and valid inputIndex are required for script verification."];
        return NO;
    }
    if (!outputScript)
    {
        [NSException raise:@"BTCScriptMachineException"  format:@"non-nil outputScript is required for script verification."];
        return NO;
    }

    BTCTransactionInput* txInput = self.transaction.inputs[self.inputIndex];
    BTCScript* inputScript = txInput.signatureScript;

    // First step: run the input script which typically places signatures, pubkeys and other static data needed for outputScript.
    if (![self runScript:inputScript error:errorOut])
    {
        return NO;
    }
    
    // Make a copy of the stack if we have P2SH script.
    // We will run deserialized P2SH script on this stack if other verifications succeed.
    BOOL shouldVerifyP2SH = [self shouldVerifyP2SH] && outputScript.isPayToScriptHashScript;
    NSMutableArray* stackForP2SH = shouldVerifyP2SH ? [_stack mutableCopy] : nil;
    
    // Second step: run output script to see that the input satisfies all conditions laid in the output script.
    if (![self runScript:outputScript error:errorOut])
    {
        return NO;
    }
    
    // We need to have something on stack
    if (_stack.count == 0)
    {
        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Stack is empty after script execution.", @"")}];
        return NO;
    }
    
    // The last value must be YES.
    if ([self boolAtIndex:-1] == NO)
    {
        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Last item on the stack is boolean NO.", @"")}];
        return NO;
    }
    
    // Additional validation for spend-to-script-hash transactions:
    if (shouldVerifyP2SH)
    {
        // BitcoinQT: scriptSig must be literals-only
        if (![inputScript isPushOnly])
        {
            if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Input script for P2SH spending must be literals-only.", @"")}];
            return NO;
        }
        
        if (stackForP2SH.count == 0)
        {
            // stackForP2SH cannot be empty here, because if it was the
            // P2SH  HASH <> EQUAL  scriptPubKey would be evaluated with
            // an empty stack and the runScript: above would return NO.
            [NSException raise:@"BTCScriptMachineException"  format:@"internal inconsistency: stackForP2SH cannot be empty at this point."];
            return NO;
        }
        
        // Instantiate the script from the last data on the stack.
        BTCScript* providedScript = [[BTCScript alloc] initWithData:[stackForP2SH lastObject]];
        
        // Remove it from the stack.
        [stackForP2SH removeObjectAtIndex:stackForP2SH.count - 1];
        
        // Replace current stack with P2SH stack.
        [self resetStack];
        _stack = stackForP2SH;
        
        if (![self runScript:providedScript error:errorOut])
        {
            return NO;
        }
        
        // We need to have something on stack
        if (_stack.count == 0)
        {
            if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Stack is empty after script execution.", @"")}];
            return NO;
        }
        
        // The last value must be YES.
        if ([self boolAtIndex:-1] == NO)
        {
            if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Last item on the stack is boolean NO.", @"")}];
            return NO;
        }
    }
    
    // If nothing failed, validation passed.
    return YES;
}


- (BOOL) runScript:(BTCScript*)script error:(NSError**)errorOut
{
    if (!script)
    {
        [NSException raise:@"BTCScriptMachineException"  format:@"non-nil script is required for -runScript:error: method."];
        return NO;
    }
    
    if (script.data.length > BTC_SCRIPT_MAX_SIZE)
    {
        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Script binary is too long.", @"")}];
        return NO;
    }
    
    _lastCodeSeparatorIndex = 0;
    
    __block BOOL opFailed = NO;
    [script enumerateOperations:^(NSUInteger opIndex, BTCOpcode opcode, NSData *pushdata, BOOL *stop) {
        
        if (![self executeOpcode:opcode data:pushdata opcodeIndex:opIndex error:errorOut])
        {
            opFailed = YES;
            *stop = YES;
        }
    }];
    
    if (opFailed)
    {
        // Error is already set by executeOpcode, return immediately.
        return NO;
    }
    
    if (_conditionStack.count > 0)
    {
        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Condition branches unbalanced.", @"")}];
        return NO;
    }
    
    return YES;
}


- (BOOL) executeOpcode:(BTCOpcode)opcode data:(NSData*)pushdata opcodeIndex:(NSUInteger)opcodeIndex error:(NSError**)errorOut
{
    if (pushdata.length > BTC_MAX_SCRIPT_ELEMENT_SIZE)
    {
        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Pushdata chunk size is too big.", @"")}];
        return NO;
    }
    
    if (opcode > OP_16 && ++_opCount > 201)
    {
        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Exceeded the allowed number of operations per script.", @"")}];
        return NO;
    }
    
    // Disabled opcodes
    
    if (opcode == OP_CAT ||
        opcode == OP_SUBSTR ||
        opcode == OP_LEFT ||
        opcode == OP_RIGHT ||
        opcode == OP_INVERT ||
        opcode == OP_AND ||
        opcode == OP_OR ||
        opcode == OP_XOR ||
        opcode == OP_2MUL ||
        opcode == OP_2DIV ||
        opcode == OP_MUL ||
        opcode == OP_DIV ||
        opcode == OP_MOD ||
        opcode == OP_LSHIFT ||
        opcode == OP_RSHIFT)
    {
        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Attempt to execute a disabled opcode.", @"")}];
        return NO;
    }
    
    BOOL shouldExecute = ([_conditionStack indexOfObject:@NO] == NSNotFound);
    
    if (shouldExecute && pushdata)
    {
        [_stack addObject:pushdata];
    }
    // this basically means that OP_VERIF and OP_VERNOTIF will always fail the script, even if not executed.
    else if (shouldExecute || (OP_IF <= opcode && opcode <= OP_ENDIF))
    {
        switch (opcode)
        {
            //
            // Push value
            //
            case OP_1NEGATE:
            case OP_1:
            case OP_2:
            case OP_3:
            case OP_4:
            case OP_5:
            case OP_6:
            case OP_7:
            case OP_8:
            case OP_9:
            case OP_10:
            case OP_11:
            case OP_12:
            case OP_13:
            case OP_14:
            case OP_15:
            case OP_16:
            {
                // ( -- value)
                BTCBigNumber* bn = [[BTCBigNumber alloc] initWithInt64:(int)opcode - (int)(OP_1 - 1)];
                [_stack addObject:bn.data];
            }
            break;
                
                
            //
            // Control
            //
            case OP_NOP:
            case OP_NOP1: case OP_NOP2: case OP_NOP3: case OP_NOP4: case OP_NOP5:
            case OP_NOP6: case OP_NOP7: case OP_NOP8: case OP_NOP9: case OP_NOP10:
            break;
            
            
            case OP_IF:
            case OP_NOTIF:
            {
                // <expression> if [statements] [else [statements]] endif
                BOOL value = NO;
                if (shouldExecute)
                {
                    if (_stack.count < 1)
                    {
                        if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                        return NO;
                    }
                    value = [self boolAtIndex:-1];
                    if (opcode == OP_NOTIF)
                    {
                        value = !value;
                    }
                    [self popFromStack];
                }
                [_conditionStack addObject:@(value)];
            }
            break;
            
            case OP_ELSE:
            {
                if (_conditionStack.count == 0)
                {
                    if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Expected an OP_IF or OP_NOTIF branch before OP_ELSE.", @"")}];
                    return NO;
                }
                
                // Invert last condition.
                BOOL f = [[_conditionStack lastObject] boolValue];
                [_conditionStack removeObjectAtIndex:_conditionStack.count - 1];
                [_conditionStack addObject:@(!f)];
            }
            break;
                
            case OP_ENDIF:
            {
                if (_conditionStack.count == 0)
                {
                    if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Expected an OP_IF or OP_NOTIF branch before OP_ENDIF.", @"")}];
                    return NO;
                }
                [_conditionStack removeObjectAtIndex:_conditionStack.count - 1];
            }
            break;
            
            case OP_VERIFY:
            {
                // (true -- ) or
                // (false -- false) and return
                if (_stack.count < 1)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                    return NO;
                }

                BOOL value = [self boolAtIndex:-1];
                if (value)
                {
                    [self popFromStack];
                }
                else
                {
                    if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"OP_VERIFY failed.", @"")}];
                    return NO;
                }
            }
            break;
                
            case OP_RETURN:
            {
                if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"OP_RETURN executed.", @"")}];
                return NO;
            }
            break;

                
            //
            // Stack ops
            //
            case OP_TOALTSTACK:
            {
                if (_stack.count < 1)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                    return NO;
                }
                [_altStack addObject:[self dataAtIndex:-1]];
                [self popFromStack];
            }
            break;
                
            case OP_FROMALTSTACK:
            {
                if (_altStack.count < 1)
                {
                    if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"%@ requires %d items on altstack", @""), BTCNameForOpcode(opcode), 1]}];
                    return NO;
                }
                [_stack addObject:_altStack[_altStack.count - 1]];
                [_altStack removeObjectAtIndex:_altStack.count - 1];
            }
            break;
                
            case OP_2DROP:
            {
                // (x1 x2 -- )
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                [self popFromStack];
                [self popFromStack];
            }
            break;
                
            case OP_2DUP:
            {
                // (x1 x2 -- x1 x2 x1 x2)
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                NSData* data1 = [self dataAtIndex:-2];
                NSData* data2 = [self dataAtIndex:-1];
                [_stack addObject:data1];
                [_stack addObject:data2];
            }
            break;
                
            case OP_3DUP:
            {
                // (x1 x2 x3 -- x1 x2 x3 x1 x2 x3)
                if (_stack.count < 3)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:3];
                    return NO;
                }
                NSData* data1 = [self dataAtIndex:-3];
                NSData* data2 = [self dataAtIndex:-2];
                NSData* data3 = [self dataAtIndex:-1];
                [_stack addObject:data1];
                [_stack addObject:data2];
                [_stack addObject:data3];
            }
            break;
                
            case OP_2OVER:
            {
                // (x1 x2 x3 x4 -- x1 x2 x3 x4 x1 x2)
                if (_stack.count < 4)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:4];
                    return NO;
                }
                NSData* data1 = [self dataAtIndex:-4];
                NSData* data2 = [self dataAtIndex:-3];
                [_stack addObject:data1];
                [_stack addObject:data2];
            }
            break;
                
            case OP_2ROT:
            {
                // (x1 x2 x3 x4 x5 x6 -- x3 x4 x5 x6 x1 x2)
                if (_stack.count < 6)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:6];
                    return NO;
                }
                NSData* data1 = [self dataAtIndex:-6];
                NSData* data2 = [self dataAtIndex:-5];
                [_stack removeObjectsInRange:NSMakeRange(_stack.count-6, 2)];
                [_stack addObject:data1];
                [_stack addObject:data2];
            }
            break;
                
            case OP_2SWAP:
            {
                // (x1 x2 x3 x4 -- x3 x4 x1 x2)
                if (_stack.count < 4)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:4];
                    return NO;
                }
                
                [self swapDataAtIndex:-4 withIndex:-2]; // x1 <-> x3
                [self swapDataAtIndex:-3 withIndex:-1]; // x2 <-> x4
            }
            break;
                
            case OP_IFDUP:
            {
                // (x -- x x)
                // (0 -- 0)
                if (_stack.count < 1)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                    return NO;
                }
                NSData* data = [self dataAtIndex:-1];
                if ([self boolAtIndex:-1])
                {
                    [_stack addObject:data];
                }
            }
            break;
                
            case OP_DEPTH:
            {
                // -- stacksize
                BTCBigNumber* bn = [[BTCBigNumber alloc] initWithInt64:_stack.count];
                [_stack addObject:bn.data];
            }
            break;
                
            case OP_DROP:
            {
                // (x -- )
                if (_stack.count < 1)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                    return NO;
                }
                [self popFromStack];
            }
            break;
                
            case OP_DUP:
            {
                // (x -- x x)
                if (_stack.count < 1)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                    return NO;
                }
                NSData* data = [self dataAtIndex:-1];
                [_stack addObject:data];
            }
            break;
                
            case OP_NIP:
            {
                // (x1 x2 -- x2)
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                [_stack removeObjectAtIndex:_stack.count - 2];
            }
            break;
                
            case OP_OVER:
            {
                // (x1 x2 -- x1 x2 x1)
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                NSData* data = [self dataAtIndex:-2];
                [_stack addObject:data];
            }
            break;
                
            case OP_PICK:
            case OP_ROLL:
            {
                // pick: (xn ... x2 x1 x0 n -- xn ... x2 x1 x0 xn)
                // roll: (xn ... x2 x1 x0 n --    ... x2 x1 x0 xn)
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                
                // Top item is a number of items to roll over.
                // Take it and pop it from the stack.
                int32_t n = [[self bigNumberAtIndex:-1] int32value];
                [self popFromStack];
                
                if (n < 0 || n >= _stack.count)
                {
                    if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Invalid number of items for %@: %d.", @""), BTCNameForOpcode(opcode), n]}];
                    return NO;
                }
                NSData* data = [self dataAtIndex: -n - 1];
                if (opcode == OP_ROLL)
                {
                    [_stack removeObjectAtIndex: -n - 1];
                }
                [_stack addObject:data];
            }
            break;
                
            case OP_ROT:
            {
                // (x1 x2 x3 -- x2 x3 x1)
                //  x2 x1 x3  after first swap
                //  x2 x3 x1  after second swap
                if (_stack.count < 3)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:3];
                    return NO;
                }
                [self swapDataAtIndex:-3 withIndex:-2];
                [self swapDataAtIndex:-2 withIndex:-1];
            }
            break;
                
            case OP_SWAP:
            {
                // (x1 x2 -- x2 x1)
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                [self swapDataAtIndex:-2 withIndex:-1];
            }
            break;
                
            case OP_TUCK:
            {
                // (x1 x2 -- x2 x1 x2)
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                NSData* data = [self dataAtIndex:-1];
                [_stack insertObject:data atIndex:_stack.count - 2];
            }
            break;
                
                
            case OP_SIZE:
            {
                // (in -- in size)
                if (_stack.count < 1)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                    return NO;
                }
                BTCBigNumber* bn = [[BTCBigNumber alloc] initWithUInt64:[self dataAtIndex:-1].length];
                [_stack addObject:bn.data];
            }
            break;


            //
            // Bitwise logic
            //
            case OP_EQUAL:
            case OP_EQUALVERIFY:
                //case OP_NOTEQUAL: // use OP_NUMNOTEQUAL
            {
                // (x1 x2 - bool)
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                NSData* x1 = [self dataAtIndex:-2];
                NSData* x2 = [self dataAtIndex:-1];
                BOOL equal = [x1 isEqual:x2];
                
                // OP_NOTEQUAL is disabled because it would be too easy to say
                // something like n != 1 and have some wiseguy pass in 1 with extra
                // zero bytes after it (numerically, 0x01 == 0x0001 == 0x000001)
                //if (opcode == OP_NOTEQUAL)
                //    equal = !equal;
                
                [self popFromStack];
                [self popFromStack];
                
                [_stack addObject:equal ? _blobTrue : _blobFalse];
                
                if (opcode == OP_EQUALVERIFY)
                {
                    if (equal)
                    {
                        [self popFromStack];
                    }
                    else
                    {
                        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"OP_EQUALVERIFY failed.", @"")}];
                        return NO;
                    }
                }
            }
            break;
                
            //
            // Numeric
            //
            case OP_1ADD:
            case OP_1SUB:
            case OP_NEGATE:
            case OP_ABS:
            case OP_NOT:
            case OP_0NOTEQUAL:
            {
                // (in -- out)
                if (_stack.count < 1)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                    return NO;
                }
                
                BTCMutableBigNumber* bn = [self bigNumberAtIndex:-1];
                
                switch (opcode)
                {
                    case OP_1ADD:       [bn add:_bigNumberOne]; break;
                    case OP_1SUB:       [bn subtract:_bigNumberOne]; break;
                    case OP_NEGATE:     [bn multiply:[[BTCBigNumber alloc] initWithInt32:-1]]; break;
                    case OP_ABS:        if ([bn less:_bigNumberZero]) [bn multiply:[BTCBigNumber negativeOne]]; break;
                    case OP_NOT:        bn.uint32value = (uint32_t)[bn isEqual:_bigNumberZero]; break;
                    case OP_0NOTEQUAL:  bn.uint32value = (uint32_t)(![bn isEqual:_bigNumberZero]); break;
                    default:            NSAssert(0, @"Invalid opcode"); break;
                }
                [self popFromStack];
                [_stack addObject:bn.data];
            }
            break;

            case OP_ADD:
            case OP_SUB:
            case OP_BOOLAND:
            case OP_BOOLOR:
            case OP_NUMEQUAL:
            case OP_NUMEQUALVERIFY:
            case OP_NUMNOTEQUAL:
            case OP_LESSTHAN:
            case OP_GREATERTHAN:
            case OP_LESSTHANOREQUAL:
            case OP_GREATERTHANOREQUAL:
            case OP_MIN:
            case OP_MAX:
            {
                // (x1 x2 -- out)
                if (_stack.count < 2)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:2];
                    return NO;
                }
                
                BTCMutableBigNumber* bn1 = [self bigNumberAtIndex:-2];
                BTCMutableBigNumber* bn2 = [self bigNumberAtIndex:-1];
                BTCMutableBigNumber* bn = nil;
                
                switch (opcode)
                {
                    case OP_ADD:
                        bn = [bn1 add:bn2];
                        break;
                        
                    case OP_SUB:
                        bn = [bn1 subtract:bn2];
                        break;
                        
                    case OP_BOOLAND:             bn = [[BTCMutableBigNumber alloc] initWithInt32:![bn1 isEqual:_bigNumberZero] && ![bn2 isEqual:_bigNumberZero]]; break;
                    case OP_BOOLOR:              bn = [[BTCMutableBigNumber alloc] initWithInt32:![bn1 isEqual:_bigNumberZero] || ![bn2 isEqual:_bigNumberZero]]; break;
                    case OP_NUMEQUAL:            bn = [[BTCMutableBigNumber alloc] initWithInt32: [bn1 isEqual:bn2]]; break;
                    case OP_NUMEQUALVERIFY:      bn = [[BTCMutableBigNumber alloc] initWithInt32: [bn1 isEqual:bn2]]; break;
                    case OP_NUMNOTEQUAL:         bn = [[BTCMutableBigNumber alloc] initWithInt32:![bn1 isEqual:bn2]]; break;
                    case OP_LESSTHAN:            bn = [[BTCMutableBigNumber alloc] initWithInt32:[bn1 less:bn2]]; break;
                    case OP_GREATERTHAN:         bn = [[BTCMutableBigNumber alloc] initWithInt32:[bn1 greater:bn2]]; break;
                    case OP_LESSTHANOREQUAL:     bn = [[BTCMutableBigNumber alloc] initWithInt32:[bn1 lessOrEqual:bn2]]; break;
                    case OP_GREATERTHANOREQUAL:  bn = [[BTCMutableBigNumber alloc] initWithInt32:[bn1 greaterOrEqual:bn2]]; break;
                    case OP_MIN:                 bn = [[bn1 min:bn2] mutableCopy]; break;
                    case OP_MAX:                 bn = [[bn1 max:bn2] mutableCopy]; break;
                    default:                     NSAssert(0, @"Invalid opcode"); break;
                }
                
                [self popFromStack];
                [self popFromStack];
                [_stack addObject:bn.data];
                
                if (opcode == OP_NUMEQUALVERIFY)
                {
                    if ([self boolAtIndex:-1])
                    {
                        [self popFromStack];
                    }
                    else
                    {
                        if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"OP_NUMEQUALVERIFY failed.", @"")}];
                        return NO;
                    }
                }
            }
            break;
                
            case OP_WITHIN:
            {
                // (x min max -- out)
                if (_stack.count < 3)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:3];
                    return NO;
                }
                
                BTCMutableBigNumber* bn1 = [self bigNumberAtIndex:-3];
                BTCMutableBigNumber* bn2 = [self bigNumberAtIndex:-2];
                BTCMutableBigNumber* bn3 = [self bigNumberAtIndex:-1];
                
                BOOL value = ([bn2 lessOrEqual:bn1] && [bn1 less:bn3]);
                
                [self popFromStack];
                [self popFromStack];
                [self popFromStack];
                
                [_stack addObject:(value ? _bigNumberTrue : _bigNumberFalse).data];
            }
            break;
            
                
            //
            // Crypto
            //
            case OP_RIPEMD160:
            case OP_SHA1:
            case OP_SHA256:
            case OP_HASH160:
            case OP_HASH256:
            {
                // (in -- hash)
                if (_stack.count < 1)
                {
                    if (errorOut) *errorOut = [self errorOpcode:opcode requiresItemsOnStack:1];
                    return NO;
                }
                
                NSData* data = [self dataAtIndex:-1];
                NSData* hash = nil;
                
                if (opcode == OP_RIPEMD160)
                {
                    hash = BTCRIPEMD160(data);
                }
                else if (opcode == OP_SHA1)
                {
                    hash = BTCSHA1(data);
                }
                else if (opcode == OP_SHA256)
                {
                    hash = BTCSHA256(data);
                }
                else if (opcode == OP_HASH160)
                {
                    hash = BTCHash160(data);
                }
                else if (opcode == OP_HASH256)
                {
                    hash = BTCHash256(data);
                }
                [self popFromStack];
                [_stack addObject:hash];
            }
            break;
            
            
            case OP_CODESEPARATOR:
            {
                // Code separator is almost never used and no one knows why it could be useful.
                // When checking signature, we use a special hash of transaction.
                // This hash should be computed after the most recent OP_CODESEPARATOR before current OP_CHECKSIG (or OP_CHECKMULTISIG).
                // Notice how we remember the index of OP_CODESEPARATOR itself, not the position after it.
                // Bitcoind will extract subscript *including* this codeseparator. But all codeseparators will be stripped out eventually
                // when we compute a hash of transaction.
                _lastCodeSeparatorIndex = opcodeIndex;
            }
            break;

            
            // TODO: more operations
                
                
            default:
                if (errorOut) *errorOut = [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Unknown opcode %d (%@).", @""), opcode, BTCNameForOpcode(opcode)]}];
                return NO;
        }
    }
    
    if (_stack.count + _altStack.count > 1000)
    {
        return NO;
    }
    
    return YES;
}

- (NSError*) errorOpcode:(BTCOpcode)opcode requiresItemsOnStack:(NSUInteger)items
{
    if (items == 1)
    {
        return [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"%@ requires %d item on stack.", @""), BTCNameForOpcode(opcode), items]}];
    }
    return [NSError errorWithDomain:BTCErrorDomain code:BTCErrorScriptError userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"%@ requires %d items on stack.", @""), BTCNameForOpcode(opcode), items]}];
}





#pragma mark - Stack Utilities

// 0 is the first item in stack, 1 is the second.
// -1 is the last item, -2 is the pre-last item.
#define BTCNormalizeIndex(list, i) (i < 0 ? (list.count + i) : i)

- (NSData*) dataAtIndex:(NSInteger)index
{
    return _stack[BTCNormalizeIndex(_stack, index)];
}

- (void) swapDataAtIndex:(NSInteger)index1 withIndex:(NSInteger)index2
{
    [_stack exchangeObjectAtIndex:BTCNormalizeIndex(_stack, index1)
                withObjectAtIndex:BTCNormalizeIndex(_stack, index2)];
}

// Returns bignum from pushdata or nil.
- (BTCMutableBigNumber*) bigNumberAtIndex:(NSInteger)index
{
    NSData* data = [self dataAtIndex:index];
    if (!data) return nil;
    
    // BitcoinQT throws "CastToBigNum() : overflow"
    if (data.length > 4)
    {
        return nil;
    }

    // Get rid of extra leading zeros like BitcoinQT does:
    // CBigNum(CBigNum(vch).getvch());
    // FIXME: It's a cargo cult here. I haven't checked myself when do these extra zeros appear and whether they really go away. [Oleg]
    BTCMutableBigNumber* bn = [[BTCMutableBigNumber alloc] initWithData:[[BTCBigNumber alloc] initWithData:data].data];
    return bn;
}

- (BOOL) boolAtIndex:(NSInteger)index
{
    NSData* data = [self dataAtIndex:index];
    if (!data) return NO;
    
    NSUInteger len = data.length;
    if (len == 0) return NO;
    
    const unsigned char* bytes = data.bytes;
    for (NSUInteger i = 0; i < len; i++)
    {
        if (bytes[i] != 0)
        {
            // Can be negative zero
            if (i == (len - 1) && bytes[i] == 0x80)
            {
                return NO;
            }
            return YES;
        }
    }
    return NO;
}

// -1 means last item
- (void) removeAtIndex:(NSInteger)index
{
    [_stack removeObjectAtIndex:BTCNormalizeIndex(_stack, index)];
}

// -1 means last item
- (void) popFromStack
{
    [_stack removeObjectAtIndex:BTCNormalizeIndex(_stack, -1)];
}

- (NSData*) trueBlob
{
    uint8_t one = 1;
    return [NSData dataWithBytes:(void*)&one length:1];
}

- (NSData*) falseBlob
{
    return [NSData data];
}

- (NSData*) zeroBlob
{
    return [NSData data];
}

@end
