/*
 * Copyright (c) 2014 Mayur Pawashe
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <XCTest/XCTest.h>

#import "ZGVirtualMemory.h"
#import "ZGSearchFunctions.h"
#import "ZGSearchData.h"
#import "ZGSearchResults.h"
#import "ZGStoredData.h"
#import "ZGDataValueExtracting.h"
#import "ZGVariableDataInfo.h"
#import "ZGSearchProgress.h"

@interface SearchVirtualMemoryTest : XCTestCase

@end

// Records the progress it is notified about
@interface ZGTestSearchProgressDelegate : NSObject <ZGSearchProgressDelegate>

@property (nonatomic, readonly) NSMutableSet<ZGSearchProgress *> *searchProgresses;
@property (nonatomic, readonly) NSMutableSet<NSNumber *> *dataTypes;

@end

@implementation ZGTestSearchProgressDelegate

- (instancetype)init
{
	self = [super init];
	if (self != nil)
	{
		_searchProgresses = [NSMutableSet set];
		_dataTypes = [NSMutableSet set];
	}
	return self;
}

- (void)progressWillBegin:(ZGSearchProgress *)searchProgress
{
	[_searchProgresses addObject:searchProgress];
}

- (void)progress:(ZGSearchProgress *)searchProgress advancedWithResultSets:(NSArray<NSData *> *)__unused resultSets totalResultSetLength:(NSUInteger)__unused totalResultSetLength resultType:(ZGSearchResultType)__unused resultType dataType:(ZGVariableType)dataType addressType:(ZGSearchResultAddressType)__unused addressType stride:(ZGMemorySize)__unused stride headerAddresses:(NSArray<NSNumber *> * _Nullable)__unused headerAddresses
{
	[_searchProgresses addObject:searchProgress];
	[_dataTypes addObject:@(dataType)];
}

@end

@implementation SearchVirtualMemoryTest
{
	ZGMemoryMap _processTask;
	NSData *_data;
	ZGMemorySize _pageSize;
}

- (void)setUp
{
    [super setUp];

	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	NSString *randomDataPath = [bundle pathForResource:@"random_data" ofType:@""];
	XCTAssertNotNil(randomDataPath);
	
	_data = [NSData dataWithContentsOfFile:randomDataPath];
	XCTAssertNotNil(_data);
	
	// We'll use our own process because it's a pain to use another one
	if (!ZGTaskForPID(getpid(), &_processTask))
	{
		XCTFail(@"Failed to grant access to task");
	}
	
	if (!ZGPageSize(_processTask, &_pageSize))
	{
		XCTFail(@"Failed to retrieve page size from task");
	}
	
	if (_pageSize * 5 != _data.length)
	{
		XCTFail(@"random_data length %lu is not 5 pages (page size %llu)", (unsigned long)_data.length, _pageSize);
	}
}

- (ZGMemoryAddress)allocateDataIntoProcess
{
	ZGMemoryAddress address = 0x0;
	if (!ZGAllocateMemory(_processTask, &address, _data.length))
	{
		XCTFail(@"Failed to retrieve page size from task");
	}
	
	XCTAssertTrue(address % _pageSize == 0);
	
	if (!ZGProtect(_processTask, address, _data.length, VM_PROT_READ | VM_PROT_WRITE))
	{
		XCTFail(@"Failed to memory protect allocated data");
	}
	
	if (!ZGWriteBytes(_processTask, address, _data.bytes, _data.length))
	{
		XCTFail(@"Failed to write data into pages");
	}
	
	// Ensure the pages will be split in at least 3 different regions.
	// Use READ|EXECUTE (not VM_PROT_ALL) because ARM64 enforces W^X.
	if (!ZGProtect(_processTask, address + _pageSize * 1, _pageSize, VM_PROT_READ | VM_PROT_EXECUTE))
	{
		XCTFail(@"Failed to change page 2 protection to READ|EXECUTE");
	}
	if (!ZGProtect(_processTask, address + _pageSize * 3, _pageSize, VM_PROT_READ | VM_PROT_EXECUTE))
	{
		XCTFail(@"Failed to change page 4 protection to READ|EXECUTE");
	}
	
	return address;
}

- (void)tearDown
{
    // Put teardown code here. This method is called after the invocation of each test method in the class.
	ZGDeallocatePort(_processTask);
	
    [super tearDown];
}

- (void)testFindingData
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	
	uint8_t firstBytes[] = {0x00, 0xB1, 0x17, 0x11, 0x34, 0x03, 0x28, 0xD7, 0xD4, 0x98, 0x4A, 0xC2};
	void *bytes = malloc(sizeof(firstBytes));
	if (bytes == NULL)
	{
		XCTFail(@"Failed to allocate memory for first bytes...");
	}
	
	memcpy(bytes, firstBytes, sizeof(firstBytes));
	
	ZGSearchData *searchData = [[ZGSearchData alloc] initWithSearchValue:bytes dataSize:sizeof(firstBytes) dataAlignment:1 pointerSize:8];
	
	ZGSearchResults *results = ZGSearchForData(_processTask, searchData, nil, ZGByteArray, 0, ZGEquals);
	
	__block BOOL foundAddress = NO;
	[results enumerateWithCount:results.count removeResults:NO usingBlock:^(const void *resultAddressData, BOOL *stop) {
		ZGMemoryAddress resultAddress = *(const ZGMemoryAddress *)resultAddressData;
		if (resultAddress == address)
		{
			foundAddress = YES;
			*stop = YES;
		}
	}];
	
	XCTAssertTrue(foundAddress);
}

- (ZGSearchData *)searchDataFromBytes:(const void *)bytes size:(ZGMemorySize)size dataType:(ZGVariableType)dataType address:(ZGMemoryAddress)address alignment:(ZGMemorySize)alignment
{
	void *copiedBytes = malloc(size);
	if (copiedBytes == NULL)
	{
		XCTFail(@"Failed to allocate memory for copied bytes...");
	}
	
	memcpy(copiedBytes, bytes, size);
	
	ZGSearchData *searchData = [[ZGSearchData alloc] initWithSearchValue:copiedBytes dataSize:size dataAlignment:alignment pointerSize:8];
	searchData.beginAddress = address;
	searchData.endAddress = address + _data.length;
	searchData.swappedValue = ZGSwappedValue(ZGProcessTypeX86_64, bytes, dataType, size);
	
	return searchData;
}

- (void)testInt8Search
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	uint8_t valueToFind = 0xB1;
	
	ZGSearchData *searchData = [self searchDataFromBytes:&valueToFind size:sizeof(valueToFind) dataType:ZGInt8 address:address alignment:1];
	searchData.savedData = [ZGStoredData storedDataFromProcessTask:_processTask beginAddress:searchData.beginAddress endAddress:searchData.endAddress protectionMode:searchData.protectionMode includeSharedMemory:NO];
	XCTAssertNotNil(searchData.savedData);
	
	ZGSearchResults *equalResults = ZGSearchForData(_processTask, searchData, nil, ZGInt8, ZGUnsigned, ZGEquals);
	XCTAssertEqual(equalResults.count, 320U);

	ZGSearchResults *equalSignedResults = ZGSearchForData(_processTask, searchData, nil, ZGInt8, ZGSigned, ZGEquals);
	XCTAssertEqual(equalSignedResults.count, 320U);

	ZGSearchResults *notEqualResults = ZGSearchForData(_processTask, searchData, nil, ZGInt8, ZGUnsigned, ZGNotEquals);
	XCTAssertEqual(notEqualResults.count, _data.length - 320U);

	ZGSearchResults *greaterThanResults = ZGSearchForData(_processTask, searchData, nil, ZGInt8, ZGUnsigned, ZGGreaterThan);
	XCTAssertEqual(greaterThanResults.count, 25014U);

	ZGSearchResults *lessThanResults = ZGSearchForData(_processTask, searchData, nil, ZGInt8, ZGUnsigned, ZGLessThan);
	XCTAssertEqual(lessThanResults.count, 56586U);
	
	searchData.shouldCompareStoredValues = YES;
	ZGSearchResults *storedEqualResults = ZGSearchForData(_processTask, searchData, nil, ZGInt8, ZGUnsigned, ZGEqualsStored);
	XCTAssertEqual(storedEqualResults.count, _data.length);
	searchData.shouldCompareStoredValues = NO;
	
	if (!ZGWriteBytes(_processTask, address + 0x1, (uint8_t []){valueToFind - 1}, 0x1))
	{
		XCTFail(@"Failed to write 2nd byte");
	}
	
	ZGSearchResults *emptyResults = [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGInt8 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO];
	
	ZGSearchResults *equalNarrowResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGEquals, emptyResults, equalResults);
	XCTAssertEqual(equalNarrowResults.count, 319U);
	
	ZGSearchResults *notEqualNarrowResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGNotEquals, emptyResults, equalResults);
	XCTAssertEqual(notEqualNarrowResults.count, 1U);
	
	ZGSearchResults *greaterThanNarrowResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGGreaterThan, emptyResults, equalResults);
	XCTAssertEqual(greaterThanNarrowResults.count, 0U);
	
	ZGSearchResults *lessThanNarrowResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGLessThan, emptyResults, equalResults);
	XCTAssertEqual(lessThanNarrowResults.count, 1U);
	
	searchData.shouldCompareStoredValues = YES;
	ZGSearchResults *storedEqualResultsNarrowed = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGEqualsStored, emptyResults, storedEqualResults);
	XCTAssertEqual(storedEqualResultsNarrowed.count, _data.length - 1);
	searchData.shouldCompareStoredValues = NO;
	
	searchData.protectionMode = ZGProtectionExecute;
	
	ZGSearchResults *equalExecuteResults = ZGSearchForData(_processTask, searchData, nil, ZGInt8, ZGUnsigned, ZGEquals);
	XCTAssertEqual(equalExecuteResults.count, 133U);
	
	// this will ignore the 2nd byte we changed since it's out of range
	ZGSearchResults *equalExecuteNarrowResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGEquals, emptyResults, equalResults);
	XCTAssertEqual(equalExecuteNarrowResults.count, 133U);
	
	ZGMemoryAddress *addressesRemoved = calloc(2, sizeof(*addressesRemoved));
	if (addressesRemoved == NULL) XCTFail(@"Failed to allocate memory for addressesRemoved");
	XCTAssertEqual(sizeof(ZGMemoryAddress), 8U);
	
	__block NSUInteger addressIndex = 0;
	[equalExecuteNarrowResults enumerateWithCount:2 removeResults:YES usingBlock:^(const void *resultAddressData, __unused BOOL *stop) {
		ZGMemoryAddress resultAddress = *(const ZGMemoryAddress *)resultAddressData;
		addressesRemoved[addressIndex] = resultAddress;
		addressIndex++;
	}];
	
	// first results do not have to be ordered
	addressesRemoved[0] ^= addressesRemoved[1];
	addressesRemoved[1] ^= addressesRemoved[0];
	addressesRemoved[0] ^= addressesRemoved[1];
	
	ZGSearchResults *equalExecuteNarrowTwiceResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGEquals, emptyResults, equalExecuteNarrowResults);
	XCTAssertEqual(equalExecuteNarrowTwiceResults.count, 131U);
	
	ZGSearchResults *searchResultsRemoved = [[ZGSearchResults alloc] initWithResultSets:@[[NSData dataWithBytes:addressesRemoved length:2 * sizeof(*addressesRemoved)]] resultType:ZGSearchResultTypeDirect dataType:ZGInt8 stride:8 unalignedAccess:NO];
	
	ZGSearchResults *equalExecuteNarrowTwiceAgainResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGEquals, searchResultsRemoved, equalExecuteNarrowResults);
	XCTAssertEqual(equalExecuteNarrowTwiceAgainResults.count, 133U);
	
	free(addressesRemoved);
	
	searchData.shouldCompareStoredValues = YES;
	ZGSearchResults *storedEqualExecuteNarrowResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt8, ZGUnsigned, ZGEqualsStored, emptyResults, storedEqualResults);
	XCTAssertEqual(storedEqualExecuteNarrowResults.count, _pageSize * 2);
	searchData.shouldCompareStoredValues = NO;
	
	if (!ZGWriteBytes(_processTask, address + 0x1, (uint8_t []){valueToFind}, 0x1))
	{
		XCTFail(@"Failed to revert 2nd byte");
	}
}

- (void)testInt16Search
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	int16_t valueToFind = -13398; // AA CB
	
	ZGSearchData *searchData = [self searchDataFromBytes:&valueToFind size:sizeof(valueToFind) dataType:ZGInt16 address:address alignment:sizeof(valueToFind)];
	
	ZGSearchResults *equalResults = ZGSearchForData(_processTask, searchData, nil, ZGInt16, ZGSigned, ZGEquals);
	XCTAssertEqual(equalResults.count, 1U);
	
	searchData.beginAddress += 0x291;
	ZGSearchResults *misalignedEqualResults = ZGSearchForData(_processTask, searchData, nil, ZGInt16, ZGSigned, ZGEquals);
	XCTAssertEqual(misalignedEqualResults.count, 1U);
	searchData.beginAddress -= 0x291;
	
	ZGSearchData *noAlignmentSearchData = [self searchDataFromBytes:&valueToFind size:sizeof(valueToFind) dataType:ZGInt16 address:address alignment:1];
	ZGSearchResults *noAlignmentEqualResults = ZGSearchForData(_processTask, noAlignmentSearchData, nil, ZGInt16, ZGSigned, ZGEquals);
	XCTAssertEqual(noAlignmentEqualResults.count, 2U);
	
	ZGMemoryAddress oldEndAddress = searchData.endAddress;
	searchData.beginAddress += 0x291;
	searchData.endAddress = searchData.beginAddress + 0x3;
	
	ZGSearchResults *noAlignmentRestrictedEqualResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt16, ZGSigned, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGInt16 stride:sizeof(ZGMemoryAddress) unalignedAccess:YES], noAlignmentEqualResults);
	XCTAssertEqual(noAlignmentRestrictedEqualResults.count, 1U);
	
	searchData.beginAddress -= 0x291;
	searchData.endAddress = oldEndAddress;
	
	int16_t swappedValue = (int16_t)CFSwapInt16((uint16_t)valueToFind);
	ZGSearchData *swappedSearchData = [self searchDataFromBytes:&swappedValue size:sizeof(swappedValue) dataType:ZGInt16 address:address alignment:sizeof(swappedValue)];
	swappedSearchData.bytesSwapped = YES;
	
	ZGSearchResults *equalSwappedResults = ZGSearchForData(_processTask, swappedSearchData, nil, ZGInt16, ZGUnsigned, ZGEquals);
	XCTAssertEqual(equalSwappedResults.count, 1U);
}

- (void)testInt32Search
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	int32_t value = -300000000;
	ZGSearchData *searchData = [self searchDataFromBytes:&value size:sizeof(value) dataType:ZGInt32 address:address alignment:sizeof(value)];
	
	int32_t *topBound = malloc(sizeof(*topBound));
	*topBound = 300000000;
	searchData.rangeValue = topBound;
	
	ZGSearchResults *betweenResults = ZGSearchForData(_processTask, searchData, nil, ZGInt32, ZGSigned, ZGGreaterThan);
	XCTAssertEqual(betweenResults.count, 2886U);
	
	int32_t *belowBound = malloc(sizeof(*belowBound));
	*belowBound = -600000000;
	searchData.rangeValue = belowBound;
	
	searchData.bytesSwapped = YES;
	
	ZGSearchResults *betweenSwappedResults = ZGSearchForData(_processTask, searchData, nil, ZGInt32, ZGSigned, ZGLessThan);
	XCTAssertEqual(betweenSwappedResults.count, 1455U);
	
	searchData.savedData = [ZGStoredData storedDataFromProcessTask:_processTask beginAddress:searchData.beginAddress endAddress:searchData.endAddress protectionMode:searchData.protectionMode includeSharedMemory:NO];
	XCTAssertNotNil(searchData.savedData);
	
	int32_t *integerReadReference = NULL;
	ZGMemorySize integerSize = sizeof(*integerReadReference);
	if (!ZGReadBytes(_processTask, address + 0x54, (void **)&integerReadReference, &integerSize))
	{
		XCTFail(@"Failed to read integer at offset 0x54");
	}
	
	int32_t integerRead = (int32_t)CFSwapInt32BigToHost(*(uint32_t *)integerReadReference);
	
	ZGFreeBytes(integerReadReference, integerSize);
	
	int32_t *additiveConstant = malloc(sizeof(*additiveConstant));
	if (additiveConstant == NULL) XCTFail(@"Failed to malloc addititive constant");
	*additiveConstant = 10;
	
	int32_t *multiplicativeConstant = malloc(sizeof(*multiplicativeConstant));
	if (multiplicativeConstant == NULL) XCTFail(@"Failed to malloc multiplicative constant");
	*multiplicativeConstant = 3;
	
	searchData.additiveConstant = additiveConstant;
	searchData.multiplicativeConstant = multiplicativeConstant;
	searchData.shouldCompareStoredValues = YES;
	
	int32_t alteredInteger = (int32_t)CFSwapInt32HostToBig((uint32_t)((integerRead * *multiplicativeConstant + *additiveConstant)));
	if (!ZGWriteBytesIgnoringProtection(_processTask, address + 0x54, &alteredInteger, sizeof(alteredInteger)))
	{
		XCTFail(@"Failed to write altered integer at offset 0x54");
	}
	
	ZGSearchResults *narrowedSwappedAndStoredResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGInt32, ZGSigned, ZGEqualsStoredLinear, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGInt32 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], betweenSwappedResults);
	XCTAssertEqual(narrowedSwappedAndStoredResults.count, 1U);
}

- (void)testInt64Search
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	uint64_t value = 0x0B765697AFAA3400;
	
	ZGSearchData *searchData = [self searchDataFromBytes:&value size:sizeof(value) dataType:ZGInt64 address:address alignment:sizeof(value)];
	ZGSearchResults *results = ZGSearchForData(_processTask, searchData, nil, ZGInt64, ZGUnsigned, ZGLessThan);
	XCTAssertEqual(results.count, 477U);

	searchData.dataAlignment = sizeof(uint32_t);

	ZGSearchResults *resultsWithHalfAlignment = ZGSearchForData(_processTask, searchData, nil, ZGInt64, ZGUnsigned, ZGLessThan);
	XCTAssertEqual(resultsWithHalfAlignment.count, 926U);

	searchData.dataAlignment = sizeof(uint64_t);

	searchData.bytesSwapped = YES;
	ZGSearchResults *bigEndianResults = ZGSearchForData(_processTask, searchData, nil, ZGInt64, ZGUnsigned, ZGLessThan);
	XCTAssertEqual(bigEndianResults.count, 450U);
}

- (void)testFloatSearch
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	float value = -0.036687f;
	ZGSearchData *searchData = [self searchDataFromBytes:&value size:sizeof(value) dataType:ZGFloat address:address alignment:sizeof(value)];
	searchData.epsilon = 0.0000001;
	
	ZGSearchResults *results = ZGSearchForData(_processTask, searchData, nil, ZGFloat, 0, ZGEquals);
	XCTAssertEqual(results.count, 1U);
	
	searchData.epsilon = 0.01;
	ZGSearchResults *resultsWithBigEpsilon = ZGSearchForData(_processTask, searchData, nil, ZGFloat, 0, ZGEquals);
	XCTAssertEqual(resultsWithBigEpsilon.count, 24U);
	
	float *bigEndianValue = malloc(sizeof(*bigEndianValue));
	if (bigEndianValue == NULL) XCTFail(@"bigEndianValue malloc'd is NULL");
	*bigEndianValue = 7522.56f;
	
	searchData.searchValue = bigEndianValue;
	searchData.bytesSwapped = YES;
	
	ZGSearchResults *bigEndianResults = ZGSearchForData(_processTask, searchData, nil, ZGFloat, 0, ZGEquals);
	XCTAssertEqual(bigEndianResults.count, 1U);
	
	searchData.epsilon = 100.0;
	ZGSearchResults *bigEndianResultsWithBigEpsilon = ZGSearchForData(_processTask, searchData, nil, ZGFloat, 0, ZGEquals);
	XCTAssertEqual(bigEndianResultsWithBigEpsilon.count, 3U);
}

- (void)testDoubleSearch
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	double value = 100.0;
	
	ZGSearchData *searchData = [self searchDataFromBytes:&value size:sizeof(value) dataType:ZGDouble address:address alignment:sizeof(value)];
	
	ZGSearchResults *results = ZGSearchForData(_processTask, searchData, nil, ZGDouble, 0, ZGGreaterThan);
	XCTAssertEqual(results.count, 2554U);

	searchData.dataAlignment = sizeof(float);
	searchData.endAddress = searchData.beginAddress + _pageSize;

	ZGSearchResults *resultsWithHalfAlignment = ZGSearchForData(_processTask, searchData, nil, ZGDouble, 0, ZGGreaterThan);
	XCTAssertEqual(resultsWithHalfAlignment.count, 995U);
	
	searchData.dataAlignment = sizeof(double);
	
	double *newValue = malloc(sizeof(*newValue));
	if (newValue == NULL) XCTFail(@"Failed to malloc newValue");
	*newValue = 4.56194e56;
	
	searchData.searchValue = newValue;
	searchData.bytesSwapped = YES;
	searchData.epsilon = 1e57;
	
	ZGSearchResults *swappedResults = ZGSearchForData(_processTask, searchData, nil, ZGDouble, 0, ZGEquals);
	XCTAssertEqual(swappedResults.count, 1238U);
}

- (void)test8BitStringSearch
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	
	char *hello = "hello";
	if (!ZGWriteBytes(_processTask, address + 96, hello, strlen(hello))) XCTFail(@"Failed to write hello string 1");
	if (!ZGWriteBytes(_processTask, address + 150, hello, strlen(hello))) XCTFail(@"Failed to write hello string 2");
	if (!ZGWriteBytes(_processTask, address + 5000, hello, strlen(hello) + 1)) XCTFail(@"Failed to write hello string 3");
	
	ZGSearchData *searchData = [self searchDataFromBytes:hello size:strlen(hello) + 1 dataType:ZGString8 address:address alignment:1];
	searchData.dataSize -= 1; // ignore null terminator for now
	
	ZGSearchResults *results = ZGSearchForData(_processTask, searchData, nil, ZGString8, 0, ZGEquals);
	XCTAssertEqual(results.count, 3U);
	
	if (!ZGWriteBytes(_processTask, address + 96, "m", 1)) XCTFail(@"Failed to write m");
	
	ZGSearchResults *narrowedResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString8, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString8 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], results);
	XCTAssertEqual(narrowedResults.count, 2U);
	
	// .shouldIncludeNullTerminator field isn't "really" used for search functions; it's just a hint for UI state
	searchData.dataSize++;
	
	ZGSearchResults *narrowedTerminatedResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString8, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString8 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], narrowedResults);
	XCTAssertEqual(narrowedTerminatedResults.count, 1U);
	
	searchData.dataSize--;
	if (!ZGWriteBytes(_processTask, address + 150, "HeLLo", strlen(hello))) XCTFail(@"Failed to write mixed case string");
	searchData.shouldIgnoreStringCase = YES;
	
	ZGSearchResults *narrowedIgnoreCaseResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString8, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString8 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], narrowedResults);
	XCTAssertEqual(narrowedIgnoreCaseResults.count, 2U);
	
	if (!ZGWriteBytes(_processTask, address + 150, "M", 1)) XCTFail(@"Failed to write capital M");
	
	ZGSearchResults *narrowedIgnoreCaseNotEqualsResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString8, 0, ZGNotEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString8 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], narrowedIgnoreCaseResults);
	XCTAssertEqual(narrowedIgnoreCaseNotEqualsResults.count, 1U);
	
	searchData.shouldIgnoreStringCase = NO;
	
	ZGSearchResults *equalResultsAgain = ZGSearchForData(_processTask, searchData, nil, ZGString8, 0, ZGEquals);
	XCTAssertEqual(equalResultsAgain.count, 1U);
	
	searchData.beginAddress = address + _pageSize;
	searchData.endAddress = address + _pageSize * 2;
	
	ZGSearchResults *notEqualResults = ZGSearchForData(_processTask, searchData, nil, ZGString8, 0, ZGNotEquals);
	XCTAssertEqual(notEqualResults.count, _pageSize - (strlen(hello) - 1)); // take account for bytes at end that won't be compared
}

- (void)test16BitStringSearch
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	
	NSString *helloString = @"hello";
	unichar *helloBytes = calloc(helloString.length + 1, sizeof(*helloBytes));
	if (helloBytes == NULL) XCTFail(@"Failed to write calloc hello bytes");
	
	[helloString getBytes:helloBytes maxLength:sizeof(*helloBytes) * helloString.length usedLength:NULL encoding:NSUTF16LittleEndianStringEncoding options:NSStringEncodingConversionAllowLossy range:NSMakeRange(0, helloString.length) remainingRange:NULL];
	
	size_t helloLength = helloString.length * sizeof(unichar);
	
	if (!ZGWriteBytes(_processTask, address + 96, helloBytes, helloLength)) XCTFail(@"Failed to write hello string 1");
	if (!ZGWriteBytes(_processTask, address + 150, helloBytes, helloLength)) XCTFail(@"Failed to write hello string 2");
	if (!ZGWriteBytes(_processTask, address + 5000, helloBytes, helloLength)) XCTFail(@"Failed to write hello string 3");
	if (!ZGWriteBytes(_processTask, address + 6001, helloBytes, helloLength)) XCTFail(@"Failed to write hello string 4");
	
	ZGSearchData *searchData = [self searchDataFromBytes:helloBytes size:helloLength + sizeof(unichar) dataType:ZGString16 address:address alignment:sizeof(unichar)];
	searchData.dataSize -= sizeof(unichar);
	
	ZGSearchResults *equalResults = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGEquals);
	XCTAssertEqual(equalResults.count, 4U);
	
	ZGSearchResults *notEqualResults = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGNotEquals);
	XCTAssertEqual(notEqualResults.count, _data.length / sizeof(unichar) - 3 - 4*5);
	
	searchData.dataAlignment = 1;
	
	ZGSearchResults *equalResultsWithNoAlignment = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGEquals);
	XCTAssertEqual(equalResultsWithNoAlignment.count, 4U);
	
	searchData.dataAlignment = 2;
	
	NSString *mooString = @"moo";
	unichar *mooBytes = calloc(mooString.length + 1, sizeof(*mooBytes));
	if (mooBytes == NULL) XCTFail(@"Failed to write calloc moo bytes");
	
	[mooString getBytes:mooBytes maxLength:sizeof(*mooBytes) * mooString.length usedLength:NULL encoding:NSUTF16LittleEndianStringEncoding options:NSStringEncodingConversionAllowLossy range:NSMakeRange(0, mooString.length) remainingRange:NULL];
	
	size_t mooLength = mooString.length * sizeof(unichar);
	if (!ZGWriteBytes(_processTask, address + 5000, mooBytes, mooLength)) XCTFail(@"Failed to write moo string");
	
	ZGSearchData *mooSearchData = [self searchDataFromBytes:mooBytes size:mooLength dataType:ZGString16 address:address alignment:sizeof(unichar)];
	
	ZGSearchResults *equalNarrowedResults = ZGNarrowSearchForData(_processTask, NO, mooSearchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResults);
	XCTAssertEqual(equalNarrowedResults.count, 1U);
	
	mooSearchData.shouldIgnoreStringCase = YES;
	const char *mooMixedCase = [@"MoO" cStringUsingEncoding:NSUTF16LittleEndianStringEncoding];
	if (!ZGWriteBytes(_processTask, address + 5000, mooMixedCase, mooLength)) XCTFail(@"Failed to write moo mixed string");
	
	ZGSearchResults *equalNarrowedIgnoreCaseResults = ZGNarrowSearchForData(_processTask, NO, mooSearchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResults);
	XCTAssertEqual(equalNarrowedIgnoreCaseResults.count, 1U);
	
	NSString *nooString = @"noo";
	unichar *nooBytes = calloc(nooString.length + 1, sizeof(unichar));
	if (nooBytes == NULL) XCTFail(@"Failed to write calloc noo bytes");
	
	[nooString getBytes:nooBytes maxLength:sizeof(*nooBytes) * nooString.length usedLength:NULL encoding:NSUTF16LittleEndianStringEncoding options:NSStringEncodingConversionAllowLossy range:NSMakeRange(0, nooString.length) remainingRange:NULL];
	
	size_t nooLength = nooString.length * sizeof(unichar);
	if (!ZGWriteBytes(_processTask, address + 5000, nooBytes, nooLength)) XCTFail(@"Failed to write noo string");
	
	ZGSearchResults *equalNarrowedIgnoreCaseFalseResults = ZGNarrowSearchForData(_processTask, NO, mooSearchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResults);
	XCTAssertEqual(equalNarrowedIgnoreCaseFalseResults.count, 0U);
	
	ZGSearchResults *notEqualNarrowedIgnoreCaseResults = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGNotEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResults);
	XCTAssertEqual(notEqualNarrowedIgnoreCaseResults.count, 1U);
	
	ZGSearchData *nooSearchData = [self searchDataFromBytes:nooBytes size:nooLength dataType:ZGString16 address:address alignment:sizeof(unichar)];
	nooSearchData.beginAddress = address + _pageSize;
	nooSearchData.endAddress = address + _pageSize * 2;
	
	ZGSearchResults *nooEqualResults = ZGSearchForData(_processTask, nooSearchData, nil, ZGString16, 0, ZGEquals);
	XCTAssertEqual(nooEqualResults.count, 0U);

	ZGSearchResults *nooNotEqualResults = ZGSearchForData(_processTask, nooSearchData, nil, ZGString16, 0, ZGNotEquals);
	XCTAssertEqual(nooNotEqualResults.count, _pageSize / 2 - 2);
	
	unichar *helloBigBytes = calloc(helloString.length + 1, sizeof(unichar));
	if (helloBigBytes == NULL) XCTFail(@"Failed to write calloc helloBigBytes");
	
	[helloString getBytes:helloBigBytes maxLength:sizeof(*helloBigBytes) * helloString.length usedLength:NULL encoding:NSUTF16BigEndianStringEncoding options:NSStringEncodingConversionAllowLossy range:NSMakeRange(0, helloString.length) remainingRange:NULL];
	
	if (!ZGWriteBytes(_processTask, address + 7000, helloBigBytes, helloLength)) XCTFail(@"Failed to write hello big string");
	
	searchData.bytesSwapped = YES;
	
	ZGSearchResults *equalResultsBig = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGEquals);
	XCTAssertEqual(equalResultsBig.count, 1U);
	
	ZGSearchResults *equalResultsBigNarrow = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsBig);
	XCTAssertEqual(equalResultsBigNarrow.count, 1U);
	
	unichar capitalHByte = 0x0;
	[@"H" getBytes:&capitalHByte maxLength:sizeof(capitalHByte) usedLength:NULL encoding:NSUTF16BigEndianStringEncoding options:NSStringEncodingConversionAllowLossy range:NSMakeRange(0, 1) remainingRange:NULL];
	
	if (!ZGWriteBytes(_processTask, address + 7000, &capitalHByte, sizeof(capitalHByte))) XCTFail(@"Failed to write capital H string");
	
	ZGSearchResults *equalResultsBigNarrowTwice = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsBigNarrow);
	XCTAssertEqual(equalResultsBigNarrowTwice.count, 0U);

	ZGSearchResults *notEqualResultsBigNarrowTwice = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGNotEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsBigNarrow);
	XCTAssertEqual(notEqualResultsBigNarrowTwice.count, 1U);

	searchData.shouldIgnoreStringCase = YES;

	ZGSearchResults *equalResultsBigNarrowThrice = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsBigNarrow);
	XCTAssertEqual(equalResultsBigNarrowThrice.count, 1U);
	
	ZGSearchResults *equalResultsBigCaseInsenitive = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGEquals);
	XCTAssertEqual(equalResultsBigCaseInsenitive.count, 1U);
	
	searchData.dataSize += sizeof(unichar);
	// .shouldIncludeNullTerminator is not necessary to set, only used for UI state
	
	ZGSearchResults *equalResultsBigCaseInsenitiveNullTerminatedNarrowed = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsBigCaseInsenitive);
	XCTAssertEqual(equalResultsBigCaseInsenitiveNullTerminatedNarrowed.count, 0U);

	unichar zero = 0x0;
	if (!ZGWriteBytes(_processTask, address + 7000 + helloLength, &zero, sizeof(zero))) XCTFail(@"Failed to write zero");
	
	ZGSearchResults *equalResultsBigCaseInsenitiveNullTerminatedNarrowedTwice = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsBigCaseInsenitive);
	XCTAssertEqual(equalResultsBigCaseInsenitiveNullTerminatedNarrowedTwice.count, 1U);

	ZGSearchResults *equalResultsBigCaseInsensitiveNullTerminated = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGEquals);
	XCTAssertEqual(equalResultsBigCaseInsensitiveNullTerminated.count, 1U);

	const ZGMemorySize regionCount = 5;
	const ZGMemorySize chancesMissedPerRegion = 5;
	ZGSearchResults *notEqualResultsBigCaseInsensitiveNullTerminated = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGNotEquals);
	XCTAssertEqual(notEqualResultsBigCaseInsensitiveNullTerminated.count, _data.length / sizeof(unichar) - regionCount * chancesMissedPerRegion - equalResultsBigCaseInsensitiveNullTerminated.count);

	searchData.shouldIgnoreStringCase = NO;
	searchData.bytesSwapped = NO;

	ZGSearchResults *equalResultsNullTerminated = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGEquals);
	XCTAssertEqual(equalResultsNullTerminated.count, 0U);

	if (!ZGWriteBytes(_processTask, address + 96 + helloLength, &zero, sizeof(zero))) XCTFail(@"Failed to write zero 2nd time");

	ZGSearchResults *equalResultsNullTerminatedTwice = ZGSearchForData(_processTask, searchData, nil, ZGString16, 0, ZGEquals);
	XCTAssertEqual(equalResultsNullTerminatedTwice.count, 1U);

	ZGSearchResults *equalResultsNullTerminatedNarrowed = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsNullTerminatedTwice);
	XCTAssertEqual(equalResultsNullTerminatedNarrowed.count, 1U);

	if (!ZGWriteBytes(_processTask, address + 96 + helloLength, helloBytes, sizeof(zero))) XCTFail(@"Failed to write first character");

	ZGSearchResults *equalResultsNullTerminatedNarrowedTwice = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsNullTerminatedNarrowed);
	XCTAssertEqual(equalResultsNullTerminatedNarrowedTwice.count, 0U);

	ZGSearchResults *notEqualResultsNullTerminatedNarrowedTwice = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGString16, 0, ZGNotEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGString16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsNullTerminatedNarrowed);
	XCTAssertEqual(notEqualResultsNullTerminatedNarrowedTwice.count, 1U);
}

- (void)testByteArraySearch
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	uint8_t bytes[] = {0xC6, 0xED, 0x8F, 0x0D};
	
	ZGSearchData *searchData = [self searchDataFromBytes:bytes size:sizeof(bytes) dataType:ZGByteArray address:address alignment:1];
	
	ZGSearchResults *equalResults = ZGSearchForData(_processTask, searchData, nil, ZGByteArray, 0, ZGEquals);
	XCTAssertEqual(equalResults.count, 1U);
	
	ZGSearchResults *notEqualResults = ZGSearchForData(_processTask, searchData, nil, ZGByteArray, 0, ZGNotEquals);
	XCTAssertEqual(notEqualResults.count, _data.length - 1 - 3*5);
	
	uint8_t changedBytes[] = {0xC8, 0xED, 0xBF, 0x0D};
	if (!ZGWriteBytes(_processTask, address + 0x21D4, changedBytes, sizeof(changedBytes))) XCTFail(@"Failed to write changed bytes");
	
	NSString *wildcardExpression = @"C? ED *F 0D";
	unsigned char *byteArrayFlags = ZGCreateFlagsForByteArrayWildcards(wildcardExpression);
	if (byteArrayFlags == NULL) XCTFail(@"Byte array flags is NULL");
	
	searchData.byteArrayFlags = byteArrayFlags;
	searchData.searchValue = ZGValueFromString(ZGProcessTypeX86_64, wildcardExpression, ZGByteArray, NULL);
	
	ZGSearchResults *equalResultsWildcards = ZGSearchForData(_processTask, searchData, nil, ZGByteArray, 0, ZGEquals);
	XCTAssertEqual(equalResultsWildcards.count, 1U);
	
	uint8_t changedBytesAgain[] = {0xD9, 0xED, 0xBF, 0x0D};
	if (!ZGWriteBytes(_processTask, address + 0x21D4, changedBytesAgain, sizeof(changedBytesAgain))) XCTFail(@"Failed to write changed bytes again");
	
	ZGSearchResults *equalResultsWildcardsNarrowed = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGByteArray, 0, ZGEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGByteArray stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsWildcards);
	XCTAssertEqual(equalResultsWildcardsNarrowed.count, 0U);
	
	ZGSearchResults *notEqualResultsWildcardsNarrowed = ZGNarrowSearchForData(_processTask, NO, searchData, nil, ZGByteArray, 0, ZGNotEquals, [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:ZGByteArray stride:sizeof(ZGMemoryAddress) unalignedAccess:NO], equalResultsWildcards);
	XCTAssertEqual(notEqualResultsWildcardsNarrowed.count, 1U);
}

- (NSArray<NSNumber *> *)addressesFromSearchResults:(ZGSearchResults *)searchResults
{
	NSMutableArray<NSNumber *> *addresses = [NSMutableArray array];
	[searchResults enumerateWithCount:searchResults.count removeResults:NO usingBlock:^(const void *resultAddressData, BOOL * __unused stop) {
		[addresses addObject:@(*(const ZGMemoryAddress *)resultAddressData)];
	}];
	return addresses;
}

- (void)testMultipleDataTypesSearch
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	
	// Store the same number as several data types
	int16_t int16Value = 1234;
	int32_t int32Value = 1234;
	float floatValue = 1234.0f;
	double doubleValue = 1234.0;
	
	if (!ZGWriteBytes(_processTask, address + 0x10, &int16Value, sizeof(int16Value))) XCTFail(@"Failed to write int16 value");
	if (!ZGWriteBytes(_processTask, address + 0x20, &int32Value, sizeof(int32Value))) XCTFail(@"Failed to write int32 value");
	if (!ZGWriteBytes(_processTask, address + 0x30, &floatValue, sizeof(floatValue))) XCTFail(@"Failed to write float value");
	if (!ZGWriteBytes(_processTask, address + 0x40, &doubleValue, sizeof(doubleValue))) XCTFail(@"Failed to write double value");
	
	NSArray<NSNumber *> *dataTypes = @[@(ZGInt16), @(ZGInt32), @(ZGFloat), @(ZGDouble)];
	NSArray<NSNumber *> *valueAddresses = @[@(address + 0x10), @(address + 0x20), @(address + 0x30), @(address + 0x40)];
	NSArray<ZGSearchData *> *searchDataArray = @[
		[self searchDataFromBytes:&int16Value size:sizeof(int16Value) dataType:ZGInt16 address:address alignment:sizeof(int16Value)],
		[self searchDataFromBytes:&int32Value size:sizeof(int32Value) dataType:ZGInt32 address:address alignment:sizeof(int32Value)],
		[self searchDataFromBytes:&floatValue size:sizeof(floatValue) dataType:ZGFloat address:address alignment:sizeof(floatValue)],
		[self searchDataFromBytes:&doubleValue size:sizeof(doubleValue) dataType:ZGDouble address:address alignment:sizeof(doubleValue)]
	];
	
	ZGTestSearchProgressDelegate *progressDelegate = [[ZGTestSearchProgressDelegate alloc] init];
	
	NSArray<ZGSearchResults *> *searchResultsArray = ZGSearchForDataOfTypes(_processTask, searchDataArray, progressDelegate, dataTypes, ZGSigned, ZGEquals);
	XCTAssertEqual(searchResultsArray.count, dataTypes.count);
	
	// Searching the data types together finds the same results as searching them separately
	NSUInteger totalCount = 0;
	for (NSUInteger dataTypeIndex = 0; dataTypeIndex < dataTypes.count; dataTypeIndex++)
	{
		ZGVariableType dataType = (ZGVariableType)dataTypes[dataTypeIndex].integerValue;
		ZGSearchResults *searchResults = searchResultsArray[dataTypeIndex];
		ZGSearchResults *expectedSearchResults = ZGSearchForData(_processTask, searchDataArray[dataTypeIndex], nil, dataType, ZGSigned, ZGEquals);
		
		NSArray<NSNumber *> *addresses = [self addressesFromSearchResults:searchResults];
		XCTAssertEqual(searchResults.dataType, dataType);
		XCTAssertEqualObjects(addresses, [self addressesFromSearchResults:expectedSearchResults]);
		XCTAssertTrue([addresses containsObject:valueAddresses[dataTypeIndex]]);
		
		totalCount += searchResults.count;
	}
	
	// The data types report their progress as one search, which is delivered on the main queue
	NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:5.0];
	while ((progressDelegate.searchProgresses.anyObject == nil || progressDelegate.searchProgresses.anyObject.progress < progressDelegate.searchProgresses.anyObject.maxProgress) && timeoutDate.timeIntervalSinceNow > 0.0)
	{
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	
	ZGSearchProgress *searchProgress = progressDelegate.searchProgresses.anyObject;
	XCTAssertEqual(progressDelegate.searchProgresses.count, 1U);
	XCTAssertEqual(searchProgress.progress, searchProgress.maxProgress);
	XCTAssertEqual(searchProgress.numberOfVariablesFound, totalCount);
	XCTAssertEqualObjects(progressDelegate.dataTypes, [NSSet setWithArray:dataTypes]);
	
	int32_t changedInt32Value = 5678;
	if (!ZGWriteBytes(_processTask, address + 0x20, &changedInt32Value, sizeof(changedInt32Value))) XCTFail(@"Failed to change int32 value");
	
	float changedFloatValue = 5678.0f;
	if (!ZGWriteBytes(_processTask, address + 0x30, &changedFloatValue, sizeof(changedFloatValue))) XCTFail(@"Failed to change float value");
	
	// First search results don't need to have every data type
	ZGMemoryAddress int16Address = address + 0x10;
	ZGSearchResults *firstInt16SearchResults = [[ZGSearchResults alloc] initWithResultSets:@[[NSData dataWithBytes:&int16Address length:sizeof(int16Address)]] resultType:ZGSearchResultTypeDirect dataType:ZGInt16 stride:sizeof(ZGMemoryAddress) unalignedAccess:NO];
	ZGSearchResults *firstSearchResults = [[ZGSearchResults alloc] initWithDataTypeSearchResults:@[firstInt16SearchResults] dataType:ZGAllNumbers];
	ZGSearchResults *laterSearchResults = [[ZGSearchResults alloc] initWithDataTypeSearchResults:searchResultsArray dataType:ZGAllNumbers];
	
	NSArray<ZGSearchResults *> *narrowSearchResultsArray = ZGNarrowSearchForDataOfTypes(_processTask, NO, searchDataArray, nil, dataTypes, ZGSigned, ZGEquals, firstSearchResults, laterSearchResults);
	XCTAssertEqual(narrowSearchResultsArray.count, dataTypes.count);
	
	// Narrowing down the data types together also matches narrowing them down separately
	for (NSUInteger dataTypeIndex = 0; dataTypeIndex < dataTypes.count; dataTypeIndex++)
	{
		ZGVariableType dataType = (ZGVariableType)dataTypes[dataTypeIndex].integerValue;
		ZGSearchResults *narrowSearchResults = narrowSearchResultsArray[dataTypeIndex];
		
		ZGSearchResults *expectedFirstSearchResults = (dataType == ZGInt16) ? firstInt16SearchResults : [[ZGSearchResults alloc] initWithResultSets:@[] resultType:ZGSearchResultTypeDirect dataType:dataType stride:sizeof(ZGMemoryAddress) unalignedAccess:NO];
		ZGSearchResults *expectedNarrowSearchResults = ZGNarrowSearchForData(_processTask, NO, searchDataArray[dataTypeIndex], nil, dataType, ZGSigned, ZGEquals, expectedFirstSearchResults, searchResultsArray[dataTypeIndex]);
		
		XCTAssertEqual(narrowSearchResults.dataType, dataType);
		XCTAssertEqualObjects([self addressesFromSearchResults:narrowSearchResults], [self addressesFromSearchResults:expectedNarrowSearchResults]);
	}
	
	XCTAssertTrue([[self addressesFromSearchResults:narrowSearchResultsArray[0]] containsObject:@(address + 0x10)]);
	XCTAssertFalse([[self addressesFromSearchResults:narrowSearchResultsArray[1]] containsObject:@(address + 0x20)]);
	XCTAssertFalse([[self addressesFromSearchResults:narrowSearchResultsArray[2]] containsObject:@(address + 0x30)]);
	XCTAssertTrue([[self addressesFromSearchResults:narrowSearchResultsArray[3]] containsObject:@(address + 0x40)]);
}

- (ZGSearchResults *)searchResultsWithAddresses:(NSArray<NSNumber *> *)addresses dataType:(ZGVariableType)dataType
{
	NSMutableData *resultSet = [NSMutableData data];
	for (NSNumber *addressNumber in addresses)
	{
		ZGMemoryAddress address = addressNumber.unsignedLongLongValue;
		[resultSet appendBytes:&address length:sizeof(address)];
	}
	
	return [[ZGSearchResults alloc] initWithResultSets:@[resultSet] resultType:ZGSearchResultTypeDirect dataType:dataType stride:sizeof(ZGMemoryAddress) unalignedAccess:NO];
}

- (void)testMultipleDataTypeSearchResults
{
	NSArray<NSNumber *> *int8Addresses = @[@0x1000, @0x1001, @0x1002, @0x1003, @0x1004, @0x1005, @0x1006, @0x1007, @0x1008, @0x1009];
	NSArray<NSNumber *> *int32Addresses = @[@0x2000, @0x2004];
	NSArray<NSNumber *> *floatAddresses = @[@0x3000, @0x3004, @0x3008, @0x300C];
	
	ZGSearchResults *searchResults = [[ZGSearchResults alloc] initWithDataTypeSearchResults:@[[self searchResultsWithAddresses:int8Addresses dataType:ZGInt8], [self searchResultsWithAddresses:int32Addresses dataType:ZGInt32], [self searchResultsWithAddresses:floatAddresses dataType:ZGFloat]] dataType:ZGAllNumbers];
	
	XCTAssertEqual(searchResults.dataType, ZGAllNumbers);
	XCTAssertEqual(searchResults.count, 16U);
	XCTAssertEqual(searchResults.stride, sizeof(ZGMemoryAddress));
	
	XCTAssertEqualObjects([self addressesFromSearchResults:[searchResults searchResultsWithDataType:ZGInt32]], int32Addresses);
	XCTAssertEqual([searchResults searchResultsWithDataType:ZGInt32].dataType, ZGInt32);
	XCTAssertNil([searchResults searchResultsWithDataType:ZGDouble]);
	
	// Removing results from search results of a data type doesn't remove them from the combined search results
	[[searchResults searchResultsWithDataType:ZGInt32] enumerateWithCount:2 removeResults:YES usingBlock:^(const void * __unused data, BOOL * __unused stop) {}];
	XCTAssertEqual(searchResults.count, 16U);
	
	NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *enumeratedAddresses = [NSMutableDictionary dictionary];
	zg_enumerate_search_results_with_data_type_t recordAddress = ^(const void *data, ZGVariableType dataType, BOOL * __unused stop) {
		NSMutableArray<NSNumber *> *addresses = enumeratedAddresses[@(dataType)];
		if (addresses == nil)
		{
			addresses = [NSMutableArray array];
			enumeratedAddresses[@(dataType)] = addresses;
		}
		[addresses addObject:@(*(const ZGMemoryAddress *)data)];
	};
	
	// Each data type gets an even share, and shares a data type has too few results for go to the others
	[searchResults enumerateWithCount:9 removeResults:YES usingDataTypeBlock:recordAddress];
	XCTAssertEqualObjects(enumeratedAddresses[@(ZGInt8)], [int8Addresses subarrayWithRange:NSMakeRange(0, 4)]);
	XCTAssertEqualObjects(enumeratedAddresses[@(ZGInt32)], int32Addresses);
	XCTAssertEqualObjects(enumeratedAddresses[@(ZGFloat)], [floatAddresses subarrayWithRange:NSMakeRange(0, 3)]);
	XCTAssertEqual(searchResults.count, 7U);
	XCTAssertEqual(searchResults.resultSets.count, 2U);
	
	// Enumerating continues with the results that were not removed
	[enumeratedAddresses removeAllObjects];
	[searchResults enumerateWithCount:100 removeResults:YES usingDataTypeBlock:recordAddress];
	XCTAssertEqualObjects(enumeratedAddresses[@(ZGInt8)], [int8Addresses subarrayWithRange:NSMakeRange(4, 6)]);
	XCTAssertNil(enumeratedAddresses[@(ZGInt32)]);
	XCTAssertEqualObjects(enumeratedAddresses[@(ZGFloat)], [floatAddresses subarrayWithRange:NSMakeRange(3, 1)]);
	XCTAssertEqual(searchResults.count, 0U);
	
	// Search results with a single data type only have search results for their data type
	ZGSearchResults *int8SearchResults = [self searchResultsWithAddresses:int8Addresses dataType:ZGInt8];
	XCTAssertEqual([int8SearchResults searchResultsWithDataType:ZGInt8], int8SearchResults);
	XCTAssertNil([int8SearchResults searchResultsWithDataType:ZGInt16]);
}

- (void)testInt32AndInt64Search
{
	ZGMemoryAddress address = [self allocateDataIntoProcess];
	
	// Store a number as a 32-bit integer followed by non-zero bytes, and as a 64-bit integer
	int32_t int32Value = 1234;
	uint32_t valueAfterInt32Value = UINT32_MAX;
	int64_t int64Value = 1234;
	
	if (!ZGWriteBytes(_processTask, address + 0x20, &int32Value, sizeof(int32Value))) XCTFail(@"Failed to write int32 value");
	if (!ZGWriteBytes(_processTask, address + 0x24, &valueAfterInt32Value, sizeof(valueAfterInt32Value))) XCTFail(@"Failed to write value after int32 value");
	if (!ZGWriteBytes(_processTask, address + 0x40, &int64Value, sizeof(int64Value))) XCTFail(@"Failed to write int64 value");
	
	NSArray<NSNumber *> *dataTypes = ZGMultipleNumberDataTypes(ZGInt32AndInt64);
	XCTAssertEqualObjects(dataTypes, (@[@(ZGInt32), @(ZGInt64)]));
	XCTAssertTrue(ZGIsMultipleNumberDataType(ZGInt32AndInt64));
	XCTAssertFalse(ZGIsMultipleNumberDataType(ZGInt64));
	
	NSArray<ZGSearchData *> *searchDataArray = @[
		[self searchDataFromBytes:&int32Value size:sizeof(int32Value) dataType:ZGInt32 address:address alignment:sizeof(int32Value)],
		[self searchDataFromBytes:&int64Value size:sizeof(int64Value) dataType:ZGInt64 address:address alignment:sizeof(int64Value)]
	];
	
	NSArray<ZGSearchResults *> *searchResultsArray = ZGSearchForDataOfTypes(_processTask, searchDataArray, nil, dataTypes, ZGSigned, ZGEquals);
	XCTAssertEqual(searchResultsArray.count, dataTypes.count);
	
	ZGSearchResults *searchResults = [[ZGSearchResults alloc] initWithDataTypeSearchResults:searchResultsArray dataType:ZGInt32AndInt64];
	XCTAssertEqual(searchResults.dataType, ZGInt32AndInt64);
	
	// The 64-bit integer's lower half is found as a 32-bit integer too, but the 32-bit integer isn't found as a 64-bit integer
	NSArray<NSNumber *> *int32Addresses = [self addressesFromSearchResults:[searchResults searchResultsWithDataType:ZGInt32]];
	NSArray<NSNumber *> *int64Addresses = [self addressesFromSearchResults:[searchResults searchResultsWithDataType:ZGInt64]];
	XCTAssertTrue([int32Addresses containsObject:@(address + 0x20)]);
	XCTAssertTrue([int32Addresses containsObject:@(address + 0x40)]);
	XCTAssertFalse([int64Addresses containsObject:@(address + 0x20)]);
	XCTAssertTrue([int64Addresses containsObject:@(address + 0x40)]);
	
	// Changing the 64-bit integer to a number that 32-bit integers can't hold narrows down both of its results
	int64_t changedInt64Value = 5000000000;
	if (!ZGWriteBytes(_processTask, address + 0x40, &changedInt64Value, sizeof(changedInt64Value))) XCTFail(@"Failed to change int64 value");
	
	ZGSearchResults *firstSearchResults = [[ZGSearchResults alloc] initWithDataTypeSearchResults:@[[self searchResultsWithAddresses:@[] dataType:ZGInt32], [self searchResultsWithAddresses:@[] dataType:ZGInt64]] dataType:ZGInt32AndInt64];
	
	NSArray<ZGSearchResults *> *narrowSearchResultsArray = ZGNarrowSearchForDataOfTypes(_processTask, NO, searchDataArray, nil, dataTypes, ZGSigned, ZGEquals, firstSearchResults, searchResults);
	XCTAssertEqual(narrowSearchResultsArray.count, dataTypes.count);
	
	NSArray<NSNumber *> *narrowInt32Addresses = [self addressesFromSearchResults:narrowSearchResultsArray[0]];
	NSArray<NSNumber *> *narrowInt64Addresses = [self addressesFromSearchResults:narrowSearchResultsArray[1]];
	XCTAssertEqual(narrowSearchResultsArray[0].dataType, ZGInt32);
	XCTAssertEqual(narrowSearchResultsArray[1].dataType, ZGInt64);
	XCTAssertTrue([narrowInt32Addresses containsObject:@(address + 0x20)]);
	XCTAssertFalse([narrowInt32Addresses containsObject:@(address + 0x40)]);
	XCTAssertFalse([narrowInt64Addresses containsObject:@(address + 0x40)]);
}

- (void)testNumberValuesEqualDoubleValues
{
	NSArray<NSString *> *numbers = @[@"1000", @"200", @"-5", @"3.5", @"-9000000000", @"0.1"];
	
	// Which data types can hold each number, when signed and unsigned
	NSDictionary<NSString *, NSArray<NSNumber *> *> *signedDataTypes = @{
		@"1000" : @[@(ZGInt16), @(ZGInt32), @(ZGInt64), @(ZGFloat), @(ZGDouble)],
		@"200" : @[@(ZGInt16), @(ZGInt32), @(ZGInt64), @(ZGFloat), @(ZGDouble)],
		@"-5" : @[@(ZGInt8), @(ZGInt16), @(ZGInt32), @(ZGInt64), @(ZGFloat), @(ZGDouble)],
		@"3.5" : @[@(ZGFloat), @(ZGDouble)],
		@"-9000000000" : @[@(ZGInt64), @(ZGFloat), @(ZGDouble)],
		@"0.1" : @[@(ZGFloat), @(ZGDouble)],
	};
	
	NSDictionary<NSString *, NSArray<NSNumber *> *> *unsignedDataTypes = @{
		@"1000" : @[@(ZGInt16), @(ZGInt32), @(ZGInt64), @(ZGFloat), @(ZGDouble)],
		@"200" : @[@(ZGInt8), @(ZGInt16), @(ZGInt32), @(ZGInt64), @(ZGFloat), @(ZGDouble)],
		@"-5" : @[@(ZGFloat), @(ZGDouble)],
		@"3.5" : @[@(ZGFloat), @(ZGDouble)],
		@"-9000000000" : @[@(ZGFloat), @(ZGDouble)],
		@"0.1" : @[@(ZGFloat), @(ZGDouble)],
	};
	
	for (NSString *number in numbers)
	{
		void *doubleValue = ZGValueFromString(ZGProcessTypeARM64, number, ZGDouble, NULL);
		
		NSMutableArray<NSNumber *> *signedHoldingDataTypes = [NSMutableArray array];
		NSMutableArray<NSNumber *> *unsignedHoldingDataTypes = [NSMutableArray array];
		for (NSNumber *dataTypeNumber in ZGMultipleNumberDataTypes(ZGAllNumbers))
		{
			ZGVariableType dataType = (ZGVariableType)dataTypeNumber.integerValue;
			void *value = ZGValueFromString(ZGProcessTypeARM64, number, dataType, NULL);
			
			if (ZGNumberValueEqualsDoubleValue(value, dataType, ZGSigned, doubleValue))
			{
				[signedHoldingDataTypes addObject:dataTypeNumber];
			}
			
			if (ZGNumberValueEqualsDoubleValue(value, dataType, ZGUnsigned, doubleValue))
			{
				[unsignedHoldingDataTypes addObject:dataTypeNumber];
			}
			
			free(value);
		}
		
		XCTAssertEqualObjects(signedHoldingDataTypes, signedDataTypes[number], @"%@", number);
		XCTAssertEqualObjects(unsignedHoldingDataTypes, unsignedDataTypes[number], @"%@", number);
		
		free(doubleValue);
	}
	
	// Search data without values, like when comparing stored values, can be searched with any data type
	XCTAssertTrue(ZGNumberValueEqualsDoubleValue(NULL, ZGInt8, ZGSigned, NULL));
}

@end
