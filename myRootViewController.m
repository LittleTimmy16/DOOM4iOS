//
// myRootViewController.m
//
// Created by Anonym on 19.10.26
//
 
#import "myRootViewController.h"
@interface myRootViewController () <UITableViewDataSource>
@property (nonatomic, strong) UITableView *logTableView;
@property (nonatomic, strong) NSMutableArray *logEntries;
@end
@implementation myRootViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ObjectiveC support!";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addButtonTapped:)];
    self.logTableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.logTableView.dataSource = self;
    [self.view addSubview:self.logTableView];
    self.logEntries = [NSMutableArray array];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.logEntries.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    cell.textLabel.text = self.logEntries[indexPath.row];
    return cell;
}
- (void)addButtonTapped:(id)sender {
    @try {
        NSString *logEntry = @"Hello, World!";
        [self.logEntries insertObject:logEntry atIndex:0];
        [self.logTableView reloadData];
    } @catch (NSException *exception) {
        NSLog(@"Exception: %@", exception);
    } @finally {
        NSLog(@"Add button tapped");
    }
}
@end